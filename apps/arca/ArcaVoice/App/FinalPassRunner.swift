import Foundation
import SwiftData
import ArcaVoiceKit
#if os(iOS)
import UIKit
#endif

/// Runs the background quality pass for a stored session (used by both live
/// recordings and Watch transfers), then optionally auto-sends the summary email.
@MainActor
enum FinalPassRunner {
    /// Sessions whose pass is running right now, keyed by directory name.
    ///
    /// The retry sweep runs at launch, on every `didBecomeActive`, and on
    /// network changes — without this, coming back to the app during a long
    /// pass would start a second one over the same audio, bill for it twice,
    /// and race to rewrite the transcript.
    private static var inFlight: Set<String> = []

    static func run(
        record: RecordingSession,
        files: [CaptureChannel: URL],
        userNotes: String?,
        ownerName: String,
        languageHints: [String],
        rosterSnapshots: [RosterSnapshot] = [],
        recordingStartedAt: Date? = nil,
        engine: TranscriptionEngine? = nil
    ) {
        guard !inFlight.contains(record.directoryName) else {
            DebugTrace.log("final pass: already running for \(record.directoryName), skipping")
            return
        }

        // Claimed up front, not on failure: if the app is quit or crashes while
        // the upload is in flight, this is the only thing left saying the
        // recording is still owed a transcript.
        record.qualityPassPending = true

        // The live pass already ran Apple's on-device recognizer over this audio
        // in real time and its output is in the store. If it covers the
        // recording, decoding the file to run the same model again is pure
        // duplicated work — promote the stored segments instead. Sessions with no
        // live transcript at all (a Watch memo, an import, a session recovered
        // after a kill) are exactly the ones that need the on-device file pass.
        let liveFallback = SessionResummarizer.transcript(from: record)
        let hasUsableLive = hasUsableLiveTranscript(record)

        guard let pipeline = EngineFactory.processingPipeline(
            engine: engine, includeOnDeviceFallback: !hasUsableLive) else {
            summarizeLiveTranscriptOnly(record: record)
            return
        }

        inFlight.insert(record.directoryName)
        Task { @MainActor in
            // Every exit below releases the retry slot: success, empty result,
            // and failure alike. Leaking one would freeze that recording out of
            // all future retries.
            defer { inFlight.remove(record.directoryName) }
            #if os(iOS)
            // The uploads themselves run on a background URLSession, which
            // `nsurlsessiond` finishes out of process — that is what actually
            // survives suspension. This assertion covers the in-process work
            // around them (chunk export, decode, summarization) for the few
            // seconds iOS still grants after the app leaves the foreground.
            let grace = BackgroundGrace()
            defer { grace.end() }
            #endif
            do {
                // Names read off the meeting screen double as vocabulary hints
                // so transcription spells them right.
                let rosterNames = RosterNameMapper.participantNames(
                    in: rosterSnapshots, ownerName: ownerName)
                let output = try await pipeline.process(
                    files: files,
                    ownerName: ownerName,
                    hints: TranscriptHints(vocabulary: rosterNames, languageCodes: languageHints),
                    userNotes: (userNotes?.isEmpty == false) ? userNotes : nil,
                    liveFallback: liveFallback.turns.isEmpty ? nil : liveFallback)

                // The on-device transcript is the only copy of what was said.
                // Replace it ONLY once the cloud pass has actually produced
                // turns — a pass that legitimately finds nothing (silence, a
                // dead tap, a service that returns zero segments) used to reach
                // `removeAll()` and leave the session "ready" and blank, which
                // is how a recorded conversation disappeared with no error.
                guard !output.transcript.turns.isEmpty else {
                    record.state = .ready
                    record.qualityPassPending = false
                    record.processingError = Self.emptyPassNotice(
                        reason: output.emptyReason,
                        keptOnDeviceTranscript: !record.segments.isEmpty)
                    try record.modelContext?.save()
                    DebugTrace.log("final pass: empty transcript for \(record.directoryName), live segments kept")
                    return
                }

                // The final pass replaces live segments wholesale — unless the
                // transcript IS those live segments, promoted because nothing
                // could transcribe the audio. Rewriting them from themselves
                // would only relabel them as final, which they are not.
                if output.transcriptSource == .finalPass {
                    record.segments.removeAll()
                    for turn in output.transcript.turns {
                        record.segments.append(StoredSegment(
                            text: turn.text, start: turn.start, end: turn.end,
                            channel: turn.channel,
                            speakerKey: output.transcript.speakerNames[turn.speakerKey] ?? turn.speakerKey,
                            isFinal: true))
                    }
                }

                // Meet/Zoom roster → transcript names: rename diarized remote
                // speakers to the names seen on their tiles.
                if output.transcriptSource == .finalPass,
                   let startedAt = recordingStartedAt, !rosterSnapshots.isEmpty {
                    let remote = record.segments.filter {
                        $0.channelRaw != CaptureChannel.microphone.rawValue
                    }
                    let turns = remote.map {
                        RosterNameMapper.TurnRef(key: $0.speakerKey ?? "Other",
                                                 start: $0.start, end: $0.end)
                    }
                    let renames = RosterNameMapper.renames(
                        snapshots: rosterSnapshots, startedAt: startedAt,
                        remoteTurns: turns, ownerName: ownerName)
                    if !renames.isEmpty {
                        for segment in remote {
                            if let name = renames[segment.speakerKey ?? "Other"] {
                                segment.speakerKey = name
                            }
                        }
                        DebugTrace.log("roster renames applied: \(renames)")
                    }
                }
                if let notes = output.notes {
                    let note = record.note ?? SessionNote(roughMarkdown: userNotes ?? "")
                    note.summaryMarkdown = notes.summaryMarkdown
                    note.enhancedMarkdown = notes.enhancedNotesMarkdown
                    note.decisionsJSON = try? JSONEncoder().encode(notes.decisions)
                    note.actionItemsJSON = try? JSONEncoder().encode(notes.actionItems)
                    record.note = note
                    if !notes.title.isEmpty {
                        record.title = notes.title
                    }
                }
                record.state = .ready
                // A channel that threw while another carried the pass leaves the
                // meeting half-transcribed. Say so rather than presenting it as
                // complete, and keep the pass pending so the next launch redoes it.
                switch (output.transcriptSource, output.channelErrors.isEmpty) {
                case (.finalPass, true):
                    record.qualityPassPending = false
                    record.processingError = nil
                case (.finalPass, false):
                    record.qualityPassPending = true
                    record.processingError = L(
                        "회의 한쪽 채널의 고품질 전사가 실패했어요 (\(output.channelErrors.joined(separator: " · "))). 일부가 빠져 있을 수 있어요.",
                        "The high-quality pass failed on one channel (\(output.channelErrors.joined(separator: " · "))). Part of this meeting may be missing.")
                    DebugTrace.log("final pass: partial channel failure — \(output.channelErrors.joined(separator: " | "))")
                case (.liveSegments, _):
                    // Notes were still written, off the live transcript. The
                    // pass stays pending so a working network heals it later.
                    record.qualityPassPending = true
                    record.processingError = L(
                        "고품질 전사를 아직 못 했어요 (\(output.channelErrors.joined(separator: " · "))). 실시간 전사로 요약했고, 오디오는 그대로 있어 다음 실행에서 다시 시도해요.",
                        "The high-quality pass hasn't landed yet (\(output.channelErrors.joined(separator: " · "))). ARCA summarized the live transcript instead; the audio is intact and it retries on the next launch.")
                    DebugTrace.log("final pass: fell back to stored live transcript for \(record.directoryName)")
                }
                // Relay merge is last-writer-wins on `updatedAt`, and the pass
                // just rewrote the transcript and the notes. Without this bump
                // the improved version loses the comparison against the other
                // device's older copy and silently never propagates — the
                // recording looks fine here and stays rough over there.
                record.touch()
                try record.modelContext?.save()

                if let notes = output.notes {
                    CompanionProgress.shared.award(.meetingSummarized)
                    SummaryNotifier.summaryReady(record: record, notes: notes)
                    sendToWatchIfWatchMemo(record: record, notes: notes)
                    await autoSendEmailIfEnabled(record: record, notes: notes)
                    autoExportToObsidianIfEnabled(record: record)
                    #if os(macOS)
                    await NotionDBAutoSync.runIfEnabled(
                        record: record, transcript: output.transcript, notes: notes)
                    #endif
                    // Last: one more model call, and nothing the user is waiting on.
                    await rememberFromMeeting(record: record, notes: notes)
                }
            } catch {
                // The live transcript stays put — it's already in `segments` and
                // nothing above this point touched it. Only the cloud half is
                // missing, so mark the session for retry rather than final.
                record.state = .ready
                record.qualityPassPending = true
                record.processingError = L(
                    "고품질 전사를 아직 못 했어요 (\(error.localizedDescription)). 기기에서 만든 전사는 그대로 있고, 연결되면 자동으로 다시 시도해요.",
                    "The high-quality pass hasn't landed yet (\(error.localizedDescription)). Your on-device transcript is intact, and ARCA retries automatically once it can reach the network.")
                try? record.modelContext?.save()
                SummaryNotifier.processingFailed(record: record, message: error.localizedDescription)
            }
        }
    }

    /// What to tell the user when the pass ran fine and still found nothing.
    ///
    /// Worded so the two cases can't be confused: an empty capture is a fact
    /// about the audio, whereas "no speech found" with an on-device transcript
    /// on file means their words are safe and only the cloud polish is missing.
    private static func emptyPassNotice(reason: ProcessingPipeline.EmptyReason?,
                                       keptOnDeviceTranscript: Bool) -> String? {
        switch reason {
        case .noAudioCaptured:
            return L("이 녹음에는 소리가 담기지 않았어요 — 오디오 파일이 비어 있어요.",
                     "This recording captured no audio — the file came back empty.")
        case .noSpeechFound, .none:
            if keptOnDeviceTranscript {
                return L("고품질 전사가 말소리를 찾지 못해서, 녹음 중에 기기에서 만든 전사를 그대로 뒀어요. 내용은 아래에 그대로 있어요.",
                         "The high-quality pass found no speech, so the transcript your device made while recording was kept. Nothing was lost — it's below.")
            }
            return L("녹음에서 말소리를 찾지 못했어요.",
                     "No speech was found in this recording.")
        }
    }

    /// Whether the stored live transcript is complete enough to stand in for a
    /// failed final pass.
    private static func hasUsableLiveTranscript(_ record: RecordingSession) -> Bool {
        let texted = record.segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return SessionRecovery.liveTranscriptCovers(
            duration: record.duration,
            lastSegmentEnd: texted.map(\.end).max() ?? 0,
            hasText: !texted.isEmpty)
    }

    /// No transcription engine is available for this session, so summarize what
    /// the live pass already wrote instead of leaving a bare transcript.
    ///
    /// An install with an Anthropic key but no OpenAI key used to get a
    /// transcript and nothing else — the message told the user to add a key and
    /// stopped there, even though the notes only ever needed the transcript.
    private static func summarizeLiveTranscriptOnly(record: RecordingSession) {
        record.state = .ready
        // Pending on purpose: adding a key (or switching engines) later heals
        // the session on the next sweep.
        record.qualityPassPending = true
        let alreadySummarized = !(record.note?.summaryMarkdown ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard let summarizer = EngineFactory.summarizer(),
              SessionResummarizer.canResummarize(record),
              !alreadySummarized else {
            record.processingError = L(
                "화자분리 전사를 켜뒀는데 OpenAI 키가 없어요. 설정에서 키를 넣거나, 전사 엔진을 '기기에서 (무료)'로 바꾸면 바로 처리돼요.",
                "Speaker-separated transcription is selected but there's no OpenAI key. Add one in Settings, or switch the transcription engine to \"On this device (free)\" and this runs right away.")
            try? record.modelContext?.save()
            return
        }
        record.processingError = L(
            "고품질 전사 대신 실시간 전사를 요약했어요. 설정에서 OpenAI 키를 넣으면 화자분리 전사로 다시 시도해요.",
            "Summarized the live transcript instead of the high-quality pass. Add an OpenAI key in Settings for a diarized transcript and this retries.")
        try? record.modelContext?.save()
        Task { @MainActor in
            do {
                let notes = try await SessionResummarizer.resummarize(record, using: summarizer)
                SummaryNotifier.summaryReady(record: record, notes: notes)
            } catch {
                DebugTrace.log("final pass: live-transcript summary failed — \(error)")
            }
        }
    }

    /// Re-runs the quality pass for every recording that never got one — a
    /// missing key, no network, a quit mid-pass, an old bug.
    ///
    /// Driven by `qualityPassPending` rather than by matching words inside
    /// `processingError`, because a recording's second chance must not depend on
    /// the phrasing of an error message.
    /// - Parameter resetStuckPasses: pass `true` only at launch. A session left
    ///   in `.processing` means the app went away mid-upload; in a brand-new
    ///   process no pass can still be running, so those are safe to reclaim.
    ///   Mid-session (e.g. on a network change) a `.processing` session really
    ///   is in flight and must be left alone.
    static func retryPending(context: ModelContext, ownerName: String,
                             languageHints: [String],
                             resetStuckPasses: Bool = false) {
        let sessions = (try? context.fetch(FetchDescriptor<RecordingSession>())) ?? []
        if resetStuckPasses {
            for record in sessions where record.state == .processing {
                record.state = .ready
                record.qualityPassPending = true
            }
        }
        for record in sessions where record.qualityPassPending {
            retry(record: record, ownerName: ownerName, languageHints: languageHints)
        }
    }

    /// Re-runs the quality pass for sessions whose last attempt failed (dead
    /// key, network, an old bug) or never finished at all — audio is still on
    /// disk, so a working key on the next launch heals the library.
    ///
    /// Complements `retryPending`: that one trusts the `qualityPassPending`
    /// flag, this one recognizes the sessions that predate the flag or were
    /// killed before anything could be written — a session killed mid-pass has
    /// no error text and sat in `.processing` forever. See
    /// `SessionRecovery.needsFinalPass`.
    static func retryFailed(context: ModelContext, ownerName: String,
                            languageHints: [String]) {
        let sessions = (try? context.fetch(FetchDescriptor<RecordingSession>())) ?? []
        for record in sessions {
            guard SessionRecovery.needsFinalPass(
                state: record.state,
                processingError: record.processingError,
                hasAudio: !record.audioAssets.isEmpty) else { continue }
            retry(record: record, ownerName: ownerName, languageHints: languageHints)
        }
    }

    /// Re-runs the pass for one recording. Returns false when there's nothing to
    /// work with (already running, no audio left on this device), so a button
    /// can stay honest about whether it did anything.
    @discardableResult
    static func retry(record: RecordingSession, ownerName: String,
                      languageHints: [String],
                      engine: TranscriptionEngine? = nil) -> Bool {
        guard record.state != .recording, record.state != .processing,
              !record.audioAssets.isEmpty,
              !inFlight.contains(record.directoryName) else { return false }
        var files: [CaptureChannel: URL] = [:]
        for asset in record.audioAssets {
            let url = SessionPaths.resolve(relativePath: asset.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            files[asset.channel] = url
        }
        guard !files.isEmpty else { return false }
        record.processingError = nil
        run(record: record, files: files,
            userNotes: record.note?.roughMarkdown,
            ownerName: ownerName, languageHints: languageHints,
            engine: engine)
        return true
    }

    // MARK: - Recovery

    /// Whether this recording still has real audio on this device.
    ///
    /// The size floor matches the pipeline's: a header-only file is a capture
    /// that never happened, and offering to "recover" it would be a false
    /// promise.
    static func hasRecoverableAudio(_ record: RecordingSession) -> Bool {
        record.audioAssets.contains { asset in
            let url = SessionPaths.resolve(relativePath: asset.relativePath)
            let size = (try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return size > 4096
        }
    }

    /// Recordings whose transcript is missing but whose audio is still here, so
    /// the text can be rebuilt from scratch.
    ///
    /// This is the repair path for sessions damaged before the destructive
    /// replace was fixed: the audio was never touched, only the transcript rows
    /// were dropped, so every one of these is fully recoverable.
    ///
    /// Deliberately `segments.isEmpty` and not "has no *final* segments": a
    /// recording that still holds its on-device transcript is readable, so
    /// re-running it is a quality upgrade, not a recovery. Bundling those into a
    /// "rebuild all" would spend money on text the user already has.
    static func recoverable(context: ModelContext) -> [RecordingSession] {
        let sessions = (try? context.fetch(FetchDescriptor<RecordingSession>())) ?? []
        return sessions
            .filter { $0.state != .recording && $0.state != .processing }
            .filter { $0.segments.isEmpty }
            .filter(hasRecoverableAudio)
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Audio seconds a recovery would send for transcription — summed per
    /// channel, because that is what actually gets billed. A two-channel
    /// one-hour meeting is two hours of audio, and quoting the meeting's
    /// wall-clock length would understate the bill by half.
    static func billableAudioSeconds(_ records: [RecordingSession]) -> Double {
        records.reduce(0) { total, record in
            total + record.audioAssets.reduce(0) { channelTotal, asset in
                let url = SessionPaths.resolve(relativePath: asset.relativePath)
                let size = (try? FileManager.default
                    .attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                guard size > 4096 else { return channelTotal }
                return channelTotal + max(asset.duration, 0)
            }
        }
    }

    /// Rebuilds transcripts for every recoverable recording.
    /// Returns how many were started.
    @discardableResult
    static func recoverAll(context: ModelContext, ownerName: String,
                           languageHints: [String],
                           engine: TranscriptionEngine? = nil) -> Int {
        var started = 0
        for record in recoverable(context: context) {
            record.qualityPassPending = true
            if retry(record: record, ownerName: ownerName,
                     languageHints: languageHints, engine: engine) {
                started += 1
            }
        }
        try? context.save()
        return started
    }

    #if os(iOS)
    /// Holds an iOS background-task assertion for as long as one final pass is
    /// running. One instance per pass, so concurrent retries don't cancel each
    /// other's assertion. Roughly 30 seconds of runtime — enough for the local
    /// work, never enough for the uploads, which is why they moved to
    /// `BackgroundUploader`.
    @MainActor
    final class BackgroundGrace {
        private var id: UIBackgroundTaskIdentifier = .invalid

        init() {
            id = UIApplication.shared.beginBackgroundTask(withName: "ARCA final pass") { [weak self] in
                Task { @MainActor in self?.end() }
            }
        }

        /// Idempotent — the expiration handler and the caller both call it.
        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }
    #endif

    /// iOS only — a recording that came from the Watch reports its summary
    /// back to the Watch, closing the wrist loop.
    private static func sendToWatchIfWatchMemo(record: RecordingSession, notes: MeetingNotes) {
        #if os(iOS)
        guard record.source == .watchMemo else { return }
        let actions = notes.actionItems.prefix(5).map { item in
            item.assigneeName.map { "\(item.text) — \($0)" } ?? item.text
        }
        PhoneWatchSync.shared.sendSummary(
            uid: record.directoryName,
            title: record.title,
            summaryMarkdown: notes.summaryMarkdown,
            actionItems: Array(actions))
        #endif
    }

    /// macOS only — sends the summary through the ARCA Composio Gmail connection.
    private static func autoSendEmailIfEnabled(record: RecordingSession, notes: MeetingNotes) async {
        #if os(macOS)
        // A pass that stays pending (partial channel failure, live fallback)
        // runs again on the next launch. Without this the same meeting mails
        // itself out on every retry.
        guard record.note?.summaryEmailedAt == nil else { return }
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "autoEmailSummary") as? Bool ?? true
        guard enabled else { return }
        let recipient = AccountDefaults.string("summaryEmailRecipient") ?? "me@thezonebio.com"
        guard !recipient.isEmpty, let sender = ComposioEmailSender.fromArcaConfig() else { return }
        do {
            try await sender.sendSummary(to: recipient, sessionTitle: record.title,
                                         notes: notes, date: record.createdAt)
            record.note?.summaryEmailedAt = .now
            try? record.modelContext?.save()
        } catch {
            record.processingError = UserFacingError.message(for: error)
            try? record.modelContext?.save()
        }
        #endif
    }

    /// macOS only — writes the completed meeting note to the ARCA vault.
    /// Prefers attaching to whatever note the user was taking during the
    /// meeting (matched by time window, no model call) over creating a
    /// separate ARCA-only file, so the two records of one meeting end up in
    /// one place.
    private static func autoExportToObsidianIfEnabled(record: RecordingSession) {
        #if os(macOS)
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "autoObsidianExport") as? Bool ?? true
        guard enabled else { return }

        do {
            _ = try ObsidianExporter.exportSessionMatchingNote(record, to: ArcaVault.resolvedRoot())
        } catch {
            DebugTrace.log("obsidian auto-export failed: \(error.localizedDescription)")
        }
        #endif
    }

    /// Meetings are where most of what ARCA should remember is said, yet until
    /// now only chats fed long-term memory. Distills the finished summary into
    /// a few durable facts, keeps them locally, and sends them to ARCA Brain.
    /// Best-effort: no key or a failed call just means no memories this time.
    private static func rememberFromMeeting(record: RecordingSession, notes: MeetingNotes) async {
        // A partial-channel failure or a live-transcript fallback keeps the pass
        // pending, so this session runs again on the next launch — without this
        // guard, the same meeting's memories get re-extracted (and re-inserted,
        // dedup being best-effort model judgment) every retry.
        guard record.note?.memoryExtractedAt == nil else { return }
        guard let key = ArcaCloud.anthropicKey, !key.isEmpty,
              let context = record.modelContext else { return }
        // Built from the note, not the raw transcript — already compact, so
        // this never hits MemoryExtractor's 6000-character truncation the way
        // a two-hour transcript would.
        var text = "Meeting: \(notes.title)\n\(notes.summaryMarkdown)"
        if !notes.decisions.isEmpty {
            text += "\nDecisions:\n- " + notes.decisions.joined(separator: "\n- ")
        }
        if !notes.actionItems.isEmpty {
            text += "\nAction items:\n- " + notes.actionItems.map(\.text).joined(separator: "\n- ")
        }
        let known = MemoryPrompt.knownFactsForDedup(
            (try? context.fetch(FetchDescriptor<MemoryFact>())) ?? [])
        let model = UserDefaults.standard.string(forKey: "chatModel") ?? "claude-sonnet-5"
        // A thrown error (bad key, network down) leaves memoryExtractedAt unset
        // so a later retry tries again; a successful call — even one that
        // extracted nothing new — marks it done so a retryable processing
        // error doesn't re-call the API on every relaunch forever.
        guard let extracted = try? await MemoryExtractor(apiKey: key, model: model)
            .extract(fromConversation: text, knownFacts: known) else { return }
        record.note?.memoryExtractedAt = .now
        guard !extracted.isEmpty else {
            try? context.save()
            return
        }
        for memory in extracted {
            context.insert(MemoryFact(text: memory.text, kind: memory.kind, source: "meeting"))
        }
        try? context.save()
        await BrainClient.remember(extracted.map {
            BrainEntry(text: $0.text, kind: $0.kind, source: "meeting",
                       sourceRef: record.directoryName, createdAt: record.createdAt)
        })
        DebugTrace.log("meeting memories: \(extracted.count) from \(record.directoryName)")
    }
}
