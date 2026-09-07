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
    /// Who the user said would be in this meeting, set before `start`.
    ///
    /// A property rather than a `start` parameter: nine call sites reach that
    /// method, most of them one-tap intents with no UI to ask from, and they all
    /// keep compiling this way.
    var plannedParticipants: [MeetingParticipant] = []

    /// Read here rather than taken from `AppServices` so the coordinator stays
    /// usable on its own; same default the rest of the app uses.
    static var ownerName: String {
        UserDefaults.standard.string(forKey: "ownerName") ?? "Me"
    }
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
    #if os(macOS)
    private let rosterWatcher = MeetingRosterWatcher()
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

            // The names go to the recognizer before the first buffer, so they
            // are spelled right in the transcript scrolling past the user —
            // this is the whole payoff of asking beforehand on an engine that
            // can't tell voices apart.
            let vocabulary = plannedParticipants.vocabulary(excluding: Self.ownerName)
            let transcriber: any LiveTranscriber
            // `legacySpeech` (UserDefaults) forces the Sequoia path on a newer
            // Mac so the fallback can be QA'd without an old machine.
            if #available(macOS 26.0, iOS 26.0, *), !UserDefaults.standard.bool(forKey: "legacySpeech") {
                transcriber = AppleLiveTranscriber(vocabulary: vocabulary)
            } else {
                // Sequoia and earlier: the older recognizer, rotated per minute.
                transcriber = LegacyLiveTranscriber(vocabulary: vocabulary)
            }
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
            liveActivity.start(title: L("회의 녹음 중", "Recording meeting"), startedAt: startedAt ?? .now)
            #endif
            #if os(macOS)
            // A call is on screen — start reading participant names off it so
            // the transcript can carry real names instead of "Speaker 1".
            if channels.contains(.systemAudio) {
                rosterWatcher.start()
            }
            #endif
            DebugTrace.log("record started, channels: \(channels.map(\.rawValue).sorted())")
            #if os(macOS)
            if includeSystemAudio && MeetingCaptureEngine.lastStartDroppedSystemAudio {
                AppServices.shared.notch.showNotice(
                    L("상대방 오디오 캡처를 못 열어 마이크만 녹음 중이에요 — 설정 > 개인정보 보호 > 화면 및 시스템 오디오 녹음 확인",
                      "Couldn't capture the other person's audio, so it's mic only — check Settings > Privacy & Security > Screen & System Audio Recording"),
                    seconds: 10)
            }
            #endif
        } catch {
            errorMessage = error.localizedDescription
            phase = .idle
            DebugTrace.log("record start failed: \(error)")
            #if os(macOS)
            AppServices.shared.notch.showNotice(
                L("녹음 시작 실패 — \(error.localizedDescription)",
                  "Couldn't start recording — \(error.localizedDescription)"),
                seconds: 10)
            #endif
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
        // A typed roster is a snapshot like any other, so everything
        // downstream — vocabulary hints for the cloud pass, and the 1:1 rename
        // that names a single remote speaker — works with no new plumbing.
        // `activeSpeaker: nil` keeps it out of the active-speaker vote, where a
        // zero offset would be rejected anyway.
        var rosterSnapshots: [RosterSnapshot] = []
        if !plannedParticipants.isEmpty {
            rosterSnapshots.append(RosterSnapshot(
                capturedAt: recordingStartedAt,
                roster: MeetingRoster(participants: plannedParticipants.map(\.name),
                                      activeSpeaker: nil)))
        }
        #if os(macOS)
        rosterSnapshots.append(contentsOf: rosterWatcher.stop())
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
            // Kept whatever the source: a voice memo can have people in it too.
            record.participants = plannedParticipants
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
                                ownerName: ownerName, languageHints: languageHints,
                                rosterSnapshots: rosterSnapshots,
                                recordingStartedAt: recordingStartedAt)
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
        #if os(macOS)
        _ = rosterWatcher.stop()
        #endif
        routerTask?.cancel()
        for task in transcriberTasks { task.cancel() }
        transcriberTasks = []
        captureSession = nil
        directoryName = nil
        meetingApp = nil
        startedAt = nil
        plannedParticipants = []
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
