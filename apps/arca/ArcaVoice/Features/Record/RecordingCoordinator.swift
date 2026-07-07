import SwiftUI
import SwiftData
import ArcaVoiceKit

/// Orchestrates one recording: capture → per-channel live transcription →
/// persistence → background final pass (high-quality transcript + notes).
@MainActor
@Observable
final class RecordingCoordinator {
    enum Phase: Equatable {
        case idle
        case recording
        case stopping
    }

    private(set) var phase: Phase = .idle
    private(set) var startedAt: Date?
    /// Finalized live segments, in arrival order.
    private(set) var finalizedSegments: [LiveSegment] = []
    /// The still-changing tail per channel, animated in the UI.
    private(set) var volatileSegments: [CaptureChannel: LiveSegment] = [:]
    var roughNotes: String = ""
    var includeSystemAudio = true
    var errorMessage: String?

    private var captureSession: (any CaptureSession)?
    private var routerTask: Task<Void, Never>?
    private var transcriberTasks: [Task<Void, Never>] = []
    private var directoryName: String?
    private var languageHints: [String] = []
    #if os(iOS)
    private let liveActivity = RecordingActivityController.shared
    #endif

    var displaySegments: [LiveSegment] {
        finalizedSegments + volatileSegments.values.sorted { $0.start < $1.start }
    }

    func start(locale: Locale, languageHints: [String] = []) async {
        guard phase == .idle else { return }
        errorMessage = nil
        finalizedSegments = []
        volatileSegments = [:]
        roughNotes = ""
        self.languageHints = languageHints

        let engine = makeDefaultCaptureEngine()
        var channels = engine.availableChannels
        if !includeSystemAudio { channels.remove(.systemAudio) }

        let dirName = UUID().uuidString
        let directory = SessionPaths.directory(for: dirName)

        do {
            let session = try await engine.start(
                config: CaptureConfig(channels: channels, outputDirectory: directory))
            captureSession = session
            directoryName = dirName
            startedAt = .now
            phase = .recording

            // Split the mixed capture stream into one stream per channel.
            var streams: [CaptureChannel: AsyncStream<CapturedBuffer>] = [:]
            var continuations: [CaptureChannel: AsyncStream<CapturedBuffer>.Continuation] = [:]
            for channel in channels {
                let (stream, continuation) = AsyncStream<CapturedBuffer>.makeStream(
                    bufferingPolicy: .bufferingNewest(128))
                streams[channel] = stream
                continuations[channel] = continuation
            }
            let routes = continuations
            routerTask = Task.detached(priority: .userInitiated) { [buffers = session.buffers] in
                for await buffer in buffers {
                    routes[buffer.channel]?.yield(buffer)
                }
                for continuation in routes.values {
                    continuation.finish()
                }
            }

            let transcriber = AppleLiveTranscriber()
            for (channel, stream) in streams {
                let task = Task { [weak self] in
                    do {
                        for try await segment in transcriber.transcribe(stream, channel: channel, locale: locale) {
                            self?.ingest(segment)
                        }
                    } catch {
                        self?.errorMessage = error.localizedDescription
                    }
                }
                transcriberTasks.append(task)
            }

            #if os(iOS)
            liveActivity.start(title: "Recording meeting", startedAt: startedAt ?? .now)
            #endif
        } catch {
            errorMessage = error.localizedDescription
            phase = .idle
        }
    }

    private func ingest(_ segment: LiveSegment) {
        if segment.isVolatile {
            volatileSegments[segment.channel] = segment
        } else {
            volatileSegments[segment.channel] = nil
            finalizedSegments.append(segment)
            #if os(iOS)
            liveActivity.update(startedAt: startedAt ?? .now, segmentCount: finalizedSegments.count)
            #endif
        }
    }

    /// Stops capture, persists the session, and kicks off the background
    /// final pass. Returns the stored session for navigation.
    @discardableResult
    func stop(modelContext: ModelContext, ownerName: String) async -> RecordingSession? {
        guard phase == .recording, let session = captureSession, let directoryName else { return nil }
        phase = .stopping

        #if os(iOS)
        liveActivity.end()
        #endif

        do {
            let artifacts = try await session.stop()
            routerTask?.cancel()
            // Let live transcribers finalize their tails.
            for task in transcriberTasks { await task.value }
            transcriberTasks = []
            captureSession = nil

            let record = RecordingSession(
                title: Self.defaultTitle(startedAt: startedAt ?? .now),
                source: artifacts.files.keys.contains(.systemAudio) ? .macMeeting : .voiceMemo,
                directoryName: directoryName
            )
            record.duration = artifacts.duration
            record.state = .processing
            for (channel, url) in artifacts.files {
                record.audioAssets.append(AudioAsset(
                    channel: channel,
                    relativePath: "\(directoryName)/\(url.lastPathComponent)",
                    duration: artifacts.duration))
            }
            for segment in finalizedSegments.sorted(by: { $0.start < $1.start }) {
                record.segments.append(StoredSegment(
                    text: segment.text, start: segment.start, end: segment.end,
                    channel: segment.channel, isFinal: false))
            }
            record.note = SessionNote(roughMarkdown: roughNotes)
            modelContext.insert(record)
            try modelContext.save()

            phase = .idle
            startedAt = nil
            FinalPassRunner.run(record: record, files: artifacts.files, userNotes: roughNotes,
                                ownerName: ownerName, languageHints: languageHints)
            return record
        } catch {
            errorMessage = error.localizedDescription
            phase = .idle
            return nil
        }
    }

    private static func defaultTitle(startedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "'Recording' MMM d, HH:mm"
        return formatter.string(from: startedAt)
    }
}
