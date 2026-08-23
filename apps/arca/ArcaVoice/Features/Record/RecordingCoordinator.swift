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
    /// Whether audio is really reaching disk. The UI reads this instead of
    /// assuming that a non-nil `startedAt` means a live recording — an
    /// interruption stops capture without stopping the clock.
    private(set) var captureHealth: CaptureHealth = .capturing
    /// Finalized live segments, in arrival order.
    private(set) var finalizedSegments: [LiveSegment] = []
    /// The still-changing tail per channel, animated in the UI.
    private(set) var volatileSegments: [CaptureChannel: LiveSegment] = [:]
    var roughNotes: String = ""
    var includeSystemAudio = true
    var errorMessage: String?
    /// Set by AppServices: capture died unrecoverably, so close the recording
    /// out rather than let the surface keep counting.
    var onCaptureLost: (() -> Void)?

    private var captureSession: (any CaptureSession)?
    private var routerTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var transcriberTasks: [Task<Void, Never>] = []
    private var directoryName: String?
    private var languageHints: [String] = []
    private var meetingApp: String?
    private var recordingStartedAt: Date?
    /// The row for the recording in progress, inserted at `start()`.
    private var liveRecord: RecordingSession?
    /// How many entries of `finalizedSegments` are already rows in the store.
    private var persistedSegmentCount = 0
    private var segmentFlushTask: Task<Void, Never>?

    /// Utterances buffered before a write, and the deadline that flushes a
    /// partial batch. A kill then costs a few seconds of transcript instead of
    /// the whole session, without touching SwiftData on every word.
    private static let segmentFlushBatch = 6
    private static let segmentFlushDelay = Duration.seconds(5)

    /// Directory of the recording in progress. The launch-time recovery scan
    /// must not mistake it for the residue of a kill.
    var activeDirectoryName: String? { phase == .idle ? nil : directoryName }
    #if os(iOS)
    private let liveActivity = RecordingActivityController.shared
    #endif
    #if os(macOS)
    private let rosterWatcher = MeetingRosterWatcher()
    #endif

    var displaySegments: [LiveSegment] {
        finalizedSegments + volatileSegments.values.sorted { $0.start < $1.start }
    }

    func start(modelContext: ModelContext, locale: Locale,
               languageHints: [String] = [], meetingApp: String? = nil) async {
        guard phase == .idle else { return }
        errorMessage = nil
        finalizedSegments = []
        volatileSegments = [:]
        roughNotes = ""
        captureHealth = .capturing
        persistedSegmentCount = 0
        liveRecord = nil
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
            recordingStartedAt = startedAt
            phase = .recording

            // Persisted before a single word is transcribed. Everything from here
            // on is recoverable: a kill leaves a row in `.recording` pointing at
            // this directory, which the launch-time scan turns into a real
            // processable session. Previously the row was only created in stop(),
            // so a kill mid-recording left an .m4a on disk that nothing in the
            // app referenced and no screen could ever show.
            let record = RecordingSession(
                title: Self.defaultTitle(startedAt: startedAt ?? .now),
                source: channels.contains(.systemAudio) ? .macMeeting : .voiceMemo,
                directoryName: dirName)
            record.state = .recording
            record.meetingApp = meetingApp
            // Provisional assets: ChannelWriter's filenames are known up front.
            // stop() replaces them with what was actually written, and the
            // recovery scan drops any that never materialized.
            for channel in channels.sorted(by: { $0.rawValue < $1.rawValue }) {
                record.audioAssets.append(AudioAsset(
                    channel: channel,
                    relativePath: "\(dirName)/\(channel.rawValue).m4a",
                    duration: 0))
            }
            record.note = SessionNote(roughMarkdown: "")
            modelContext.insert(record)
            do {
                try modelContext.save()
                liveRecord = record
            } catch {
                // Not fatal: recording continues and stop() will try again.
                DebugTrace.log("record: could not persist the session row at start — \(error)")
            }

            // Capture reports interruptions here so the surface can stop
            // claiming to record when the audio engine is down.
            healthTask = Task { @MainActor [weak self] in
                for await health in session.health {
                    self?.applyHealth(health)
                }
            }

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
                    "상대방 오디오 캡처를 못 열어 마이크만 녹음 중이에요 — 설정 > 개인정보 보호 > 화면 및 시스템 오디오 녹음 확인",
                    seconds: 10)
            }
            #endif
        } catch {
            errorMessage = error.localizedDescription
            phase = .idle
            DebugTrace.log("record start failed: \(error)")
            #if os(macOS)
            AppServices.shared.notch.showNotice("녹음 시작 실패 — \(error.localizedDescription)", seconds: 10)
            #endif
        }
    }

    private func ingest(_ segment: LiveSegment) {
        if segment.isVolatile {
            volatileSegments[segment.channel] = segment
        } else {
            volatileSegments[segment.channel] = nil
            finalizedSegments.append(segment)
            scheduleSegmentFlush()
            #if os(iOS)
            liveActivity.update(startedAt: startedAt ?? .now, segmentCount: finalizedSegments.count)
            #endif
        }
    }

    private func applyHealth(_ health: CaptureHealth) {
        guard phase == .recording else { return }
        captureHealth = health
        switch health {
        case .capturing:
            DebugTrace.log("record: capture healthy")
        case .interrupted(let reason):
            DebugTrace.log("record: capture interrupted — \(reason)")
            // Anything transcribed so far is worth committing now: an
            // interruption is often the last event before a kill.
            flushLiveState()
            #if os(macOS)
            AppServices.shared.notch.showNotice("녹음 일시중지 — \(reason)", seconds: 8)
            #endif
        case .stopped(let reason):
            DebugTrace.log("record: capture lost — \(reason)")
            errorMessage = reason
            #if os(macOS)
            AppServices.shared.notch.showNotice("녹음 중단 — \(reason)", seconds: 12)
            #endif
            // Audio is dead. Close the recording out with what was captured
            // instead of leaving the surface counting time over nothing.
            onCaptureLost?()
        }
    }

    // MARK: - Incremental persistence

    private func scheduleSegmentFlush() {
        if finalizedSegments.count - persistedSegmentCount >= Self.segmentFlushBatch {
            flushLiveState()
            return
        }
        guard segmentFlushTask == nil else { return }
        segmentFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.segmentFlushDelay)
            guard let self, !Task.isCancelled else { return }
            self.segmentFlushTask = nil
            self.flushLiveState()
        }
    }

    /// Commits newly finalized segments and the user's rough notes to the store.
    ///
    /// Segments are written in arrival order rather than sorted: every reader
    /// (`transcriptMarkdown`, `SessionResummarizer.transcript`) already sorts by
    /// `start`, and sorting here would need the whole session in hand, which is
    /// exactly what incremental writing is avoiding.
    private func flushLiveState() {
        segmentFlushTask?.cancel()
        segmentFlushTask = nil
        guard let record = liveRecord else { return }
        var changed = false
        if persistedSegmentCount < finalizedSegments.count {
            for segment in finalizedSegments[persistedSegmentCount...] {
                record.segments.append(StoredSegment(
                    text: segment.text, start: segment.start, end: segment.end,
                    channel: segment.channel, isFinal: false))
            }
            persistedSegmentCount = finalizedSegments.count
            changed = true
        }
        // Typed notes are lost to a kill the same way segments were.
        if record.note?.roughMarkdown != roughNotes {
            if let note = record.note {
                note.roughMarkdown = roughNotes
            } else {
                record.note = SessionNote(roughMarkdown: roughNotes)
            }
            changed = true
        }
        guard changed else { return }
        record.touch()
        do {
            try record.modelContext?.save()
        } catch {
            DebugTrace.log("record: incremental save failed — \(error)")
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
        let startedAtSnapshot = recordingStartedAt ?? startedAt ?? .now
        // Freeze the UI timers the moment the user asks to stop.
        startedAt = nil

        #if os(iOS)
        liveActivity.end()
        #endif
        #if os(macOS)
        let rosterSnapshots = rosterWatcher.stop()
        #else
        let rosterSnapshots: [RosterSnapshot] = []
        #endif

        do {
            let artifacts = try await withTimeout(seconds: 20) { try await session.stop() }
            healthTask?.cancel()
            healthTask = nil
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

            // The row already exists — it was inserted at start(). Finalize it
            // rather than creating a second one. A nil `liveRecord` can only mean
            // that insert failed, so fall back to creating one now instead of
            // dropping the recording on the floor.
            let record: RecordingSession
            if let existing = liveRecord {
                record = existing
            } else {
                record = RecordingSession(
                    title: Self.defaultTitle(startedAt: startedAtSnapshot),
                    source: .voiceMemo,
                    directoryName: directoryName)
                modelContext.insert(record)
                liveRecord = record
            }
            record.source = artifacts.files.keys.contains(.systemAudio) ? .macMeeting : .voiceMemo
            if record.source == .macMeeting {
                record.meetingApp = meetingApp
            }
            record.duration = artifacts.duration
            record.state = .processing
            record.processingError = nil
            // Replace the provisional assets with the files that really exist —
            // a dropped system-audio tap leaves a channel that never wrote.
            record.audioAssets.removeAll()
            for (channel, url) in artifacts.files {
                record.audioAssets.append(AudioAsset(
                    channel: channel,
                    relativePath: "\(directoryName)/\(url.lastPathComponent)",
                    duration: artifacts.duration))
            }
            // Commits the transcript tail and the final rough notes; everything
            // before it is already stored.
            flushLiveState()
            record.touch()
            try modelContext.save()

            liveRecord = nil
            persistedSegmentCount = 0
            phase = .idle
            startedAt = nil
            recordingStartedAt = nil
            FinalPassRunner.run(record: record, files: artifacts.files, userNotes: roughNotes,
                                ownerName: ownerName, languageHints: languageHints,
                                rosterSnapshots: rosterSnapshots,
                                recordingStartedAt: startedAtSnapshot)
            return record
        } catch {
            errorMessage = error.localizedDescription
            forceReset()
            return nil
        }
    }

    /// Last-resort teardown: cancel everything and return to idle. Audio that
    /// was written so far stays on disk, and the row inserted at `start()` is
    /// moved into `.processing` so the retry sweep finishes the job — leaving it
    /// in `.recording` would strand it, because nothing is recording any more.
    func forceReset() {
        #if os(macOS)
        _ = rosterWatcher.stop()
        #endif
        healthTask?.cancel()
        healthTask = nil
        routerTask?.cancel()
        for task in transcriberTasks { task.cancel() }
        transcriberTasks = []
        if let session = captureSession {
            captureSession = nil
            // Dropping the reference is not enough: the engine keeps running, the
            // output file stays open, and on iOS the audio-session claim is never
            // released — which would then block voice chat and playback forever.
            Task.detached { _ = try? await session.stop() }
        }
        flushLiveState()
        if let record = liveRecord {
            if record.duration == 0, let startedAt = recordingStartedAt {
                record.duration = Date.now.timeIntervalSince(startedAt)
            }
            record.state = .processing
            record.touch()
            try? record.modelContext?.save()
        }
        liveRecord = nil
        persistedSegmentCount = 0
        directoryName = nil
        meetingApp = nil
        startedAt = nil
        recordingStartedAt = nil
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
