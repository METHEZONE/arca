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
    private var meetingApp: String?
    #if os(iOS)
    private let liveActivity = RecordingActivityController.shared
    #endif

    var displaySegments: [LiveSegment] {
        finalizedSegments + volatileSegments.values.sorted { $0.start < $1.start }
    }

    func start(locale: Locale, languageHints: [String] = [], meetingApp: String? = nil) async {
        guard phase == .idle else { return }
        errorMessage = nil
        finalizedSegments = []
        volatileSegments = [:]
        roughNotes = ""
        self.languageHints = languageHints
        self.meetingApp = meetingApp

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
    ///
    /// This must ALWAYS reach `.idle` — a hang here leaves the recording UI
    /// (notch timer, island) running forever. Every await is bounded.
    @discardableResult
    func stop(modelContext: ModelContext, ownerName: String) async -> RecordingSession? {
        guard phase != .stopping else { return nil }
        guard phase == .recording, let session = captureSession, let directoryName else {
            // Inconsistent state (recording flag without a live session) must
            // reset rather than silently return and wedge the timer.
            forceReset()
            return nil
        }
        phase = .stopping
        let recordingStartedAt = startedAt ?? .now
        // Freeze the UI timers the moment the user asks to stop.
        startedAt = nil

        #if os(iOS)
        liveActivity.end()
        #endif

        do {
            let artifacts = try await withTimeout(seconds: 20) { try await session.stop() }
            routerTask?.cancel()
            // Let live transcribers finalize their tails — bounded, because a
            // wedged analyzer must not hold the whole app in "stopping".
            for task in transcriberTasks {
                let watchdog = Task { try? await Task.sleep(for: .seconds(8)); task.cancel() }
                await task.value
                watchdog.cancel()
            }
            transcriberTasks = []
            captureSession = nil

            let record = RecordingSession(
                title: Self.defaultTitle(startedAt: recordingStartedAt),
                source: artifacts.files.keys.contains(.systemAudio) ? .macMeeting : .voiceMemo,
                directoryName: directoryName
            )
            if record.source == .macMeeting {
                record.meetingApp = meetingApp
            }
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
            forceReset()
            return nil
        }
    }

    /// Last-resort teardown: cancel everything and return to idle. Audio that
    /// was written so far stays on disk; retryFailed can heal it on relaunch.
    func forceReset() {
        routerTask?.cancel()
        for task in transcriberTasks { task.cancel() }
        transcriberTasks = []
        captureSession = nil
        directoryName = nil
        meetingApp = nil
        startedAt = nil
        phase = .idle
        #if os(iOS)
        liveActivity.end()
        #endif
    }

    /// Runs an async throwing operation with a hard deadline.
    private func withTimeout<T: Sendable>(
        seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CancellationError()
            }
            guard let first = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return first
        }
    }

    private static func defaultTitle(startedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "'Recording' MMM d, HH:mm"
        return formatter.string(from: startedAt)
    }
}
