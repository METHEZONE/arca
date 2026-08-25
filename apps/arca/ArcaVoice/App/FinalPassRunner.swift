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
    /// The retry sweep now matches on state rather than on an error string, and
    /// runs both at launch and on every `didBecomeActive` — without this, coming
    /// back to the app during a long pass would start a second one over the same
    /// audio and both would race to rewrite the transcript.
    private static var inFlight: Set<String> = []

    static func run(
        record: RecordingSession,
        files: [CaptureChannel: URL],
        userNotes: String?,
        ownerName: String,
        languageHints: [String],
        rosterSnapshots: [RosterSnapshot] = [],
        recordingStartedAt: Date? = nil
    ) {
        guard !inFlight.contains(record.directoryName) else {
            DebugTrace.log("final pass: already running for \(record.directoryName), skipping")
            return
        }

        // The live pass already ran Apple's on-device recognizer over this audio
        // in real time and its output is in the store. If it covers the
        // recording, decoding the file to run the same model again is pure
        // duplicated work — promote the stored segments instead. Sessions with no
        // live transcript at all (a Watch memo, an import, a session recovered
        // after a kill) are exactly the ones that need the on-device file pass.
        let liveFallback = SessionResummarizer.transcript(from: record)
        let hasUsableLive = hasUsableLiveTranscript(record)

        guard let pipeline = EngineFactory.processingPipeline(
            includeOnDeviceFallback: !hasUsableLive) else {
            summarizeLiveTranscriptOnly(record: record)
            return
        }

        inFlight.insert(record.directoryName)
        Task { @MainActor in
            defer { inFlight.remove(record.directoryName) }
            #if os(iOS)
            // The uploads themselves now run on a background URLSession, which
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

                // A pass that came back with nothing must never delete what the
                // live transcript already captured — that turned one failed
                // transcription into permanent data loss. Keep the live text,
                // record a retryable error, and stop here.
                guard !output.transcript.turns.isEmpty else {
                    record.state = .ready
                    record.processingError = "High-quality pass failed: transcription returned no speech, so the live transcript was kept. Audio is intact — it will retry on the next launch."
                    try? record.modelContext?.save()
                    DebugTrace.log("final pass: empty transcript for \(record.directoryName), live segments kept")
                    SummaryNotifier.processingFailed(
                        record: record, message: "전사 결과가 비어 있어 라이브 전사를 유지했습니다.")
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
                // complete, and keep the retry prefix so the next launch redoes it.
                switch (output.transcriptSource, output.channelErrors.isEmpty) {
                case (.finalPass, true):
                    record.processingError = nil
                case (.finalPass, false):
                    record.processingError = "High-quality pass failed on a channel: \(output.channelErrors.joined(separator: " · ")). Part of this meeting may be missing."
                    DebugTrace.log("final pass: partial channel failure — \(output.channelErrors.joined(separator: " | "))")
                case (.liveSegments, _):
                    // Notes were still written, off the live transcript. The
                    // retry prefix stays so a working network heals it later.
                    record.processingError = "High-quality pass failed: \(output.channelErrors.joined(separator: " · ")). 실시간 전사로 요약했고, 오디오는 그대로 있어 다음 실행에서 다시 시도해요."
                    DebugTrace.log("final pass: fell back to stored live transcript for \(record.directoryName)")
                }
                record.touch()
                try record.modelContext?.save()

                if let notes = output.notes {
                    SummaryNotifier.summaryReady(record: record, notes: notes)
                    sendToWatchIfWatchMemo(record: record, notes: notes)
                    await autoSendEmailIfEnabled(record: record, notes: notes)
                    autoExportToObsidianIfEnabled(record: record)
                    await autoRememberMeetingIfEnabled(record: record, notes: notes)
                    #if os(macOS)
                    await NotionDBAutoSync.runIfEnabled(
                        record: record, transcript: output.transcript, notes: notes)
                    #endif
                }
            } catch {
                record.state = .ready
                record.processingError = "High-quality pass failed: \(error.localizedDescription)"
                try? record.modelContext?.save()
                SummaryNotifier.processingFailed(record: record, message: error.localizedDescription)
            }
        }
    }

    /// Re-runs the quality pass for sessions whose last attempt failed (dead
    /// key, network, an old bug) or never finished at all — audio is still on
    /// disk, so a working key on the next launch heals the library.
    ///
    /// Matching used to be error-string-only, which silently excluded the worst
    /// case: a session killed mid-pass has no error text (the app died before it
    /// could write one) and sat in `.processing` forever. See
    /// `SessionRecovery.needsFinalPass`.
    static func retryFailed(context: ModelContext, ownerName: String,
                            languageHints: [String]) {
        let sessions = (try? context.fetch(FetchDescriptor<RecordingSession>())) ?? []
        for record in sessions {
            guard SessionRecovery.needsFinalPass(
                state: record.state,
                processingError: record.processingError,
                hasAudio: !record.audioAssets.isEmpty) else { continue }
            var files: [CaptureChannel: URL] = [:]
            for asset in record.audioAssets {
                let url = SessionPaths.resolve(relativePath: asset.relativePath)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                files[asset.channel] = url
            }
            guard !files.isEmpty else { continue }
            record.processingError = nil
            run(record: record, files: files,
                userNotes: record.note?.roughMarkdown,
                ownerName: ownerName, languageHints: languageHints)
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
        let alreadySummarized = !(record.note?.summaryMarkdown ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard let summarizer = EngineFactory.summarizer(),
              SessionResummarizer.canResummarize(record),
              !alreadySummarized else {
            record.processingError = "High-quality pass failed: no OpenAI API key, so only the live transcript was saved. Add a key in Settings for a high-quality diarized transcript."
            try? record.modelContext?.save()
            return
        }
        // Retryable prefix on purpose: adding a key later heals the session.
        record.processingError = "High-quality pass failed: no OpenAI API key — summarized the live transcript instead. Add a key in Settings for a high-quality diarized transcript."
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
            record.processingError = error.localizedDescription
            try? record.modelContext?.save()
        }
        #endif
    }

    /// Distills the meeting into durable memory — the same fact-extraction
    /// `ChatSession.endConversation()` already runs when a chat closes, just
    /// never wired to meetings. Every session used to leave zero trace in
    /// long-term memory once its note was written (measured: 91 finished
    /// meetings, 0 memory facts from any of them) — chat had no way to recall
    /// what happened in a meeting, only what was said directly to it. Runs on
    /// both platforms, unlike the Obsidian export below, because remembering
    /// is core behavior, not a macOS-only integration.
    private static func autoRememberMeetingIfEnabled(record: RecordingSession, notes: MeetingNotes) async {
        // A partial-channel failure or a live-transcript fallback keeps
        // `processingError` set to a retryable string, so this session's final
        // pass runs again on the next launch — without this guard, the same
        // meeting's memories get re-extracted (and re-inserted, dedup being
        // best-effort model judgment, not a hard constraint) every retry.
        guard record.note?.memoryExtractedAt == nil else { return }
        guard let key = KeychainStore.get(.anthropic), !key.isEmpty else { return }
        guard let context = record.modelContext else { return }

        var lines = ["Meeting: \(notes.title)", "", notes.summaryMarkdown]
        if !notes.decisions.isEmpty {
            lines.append("")
            lines.append("Decisions:")
            lines.append(contentsOf: notes.decisions.map { "- \($0)" })
        }
        if !notes.actionItems.isEmpty {
            lines.append("")
            lines.append("Action items:")
            lines.append(contentsOf: notes.actionItems.map { item in
                item.assigneeName.map { "- \(item.text) (\($0))" } ?? "- \(item.text)"
            })
        }
        // Built from the note, not the raw transcript — already compact, so
        // this never hits MemoryExtractor's 6000-character truncation the way
        // a two-hour transcript would.
        let meetingRecord = lines.joined(separator: "\n")

        let known = MemoryPrompt.knownFactsForDedup(
            (try? context.fetch(FetchDescriptor<MemoryFact>())) ?? [])
        let model = UserDefaults.standard.string(forKey: "chatModel") ?? "claude-sonnet-5"
        // A thrown error (bad key, network down) leaves memoryExtractedAt unset
        // so a later retry tries again; a successful call — even one that
        // extracted nothing new — marks it done so a retryable processing
        // error doesn't re-call the API on every relaunch forever.
        guard let extracted = try? await MemoryExtractor(apiKey: key, model: model)
            .extract(fromConversation: meetingRecord, knownFacts: known) else { return }
        record.note?.memoryExtractedAt = .now
        for memory in extracted {
            context.insert(MemoryFact(text: memory.text, kind: memory.kind, source: "meeting"))
        }
        try? context.save()
    }

    /// macOS only — writes the completed meeting note to the linked Obsidian
    /// vault. Prefers attaching to whatever note the user was taking during
    /// the meeting (matched by time window, no model call) over creating a
    /// separate ARCA-only file, so the two records of one meeting end up in
    /// one place.
    private static func autoExportToObsidianIfEnabled(record: RecordingSession) {
        #if os(macOS)
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "autoObsidianExport") as? Bool ?? true
        guard enabled,
              let path = AccountDefaults.string("obsidianVaultPath"),
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        do {
            let expanded = (path as NSString).expandingTildeInPath
            _ = try ObsidianExporter.exportSessionMatchingNote(record, to: URL(fileURLWithPath: expanded))
        } catch {
            DebugTrace.log("obsidian auto-export failed: \(error.localizedDescription)")
        }
        #endif
    }
}
