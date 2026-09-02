import Foundation
import SwiftData
import ArcaVoiceKit

/// Runs the background quality pass for a stored session (used by both live
/// recordings and Watch transfers), then optionally auto-sends the summary email.
@MainActor
enum FinalPassRunner {
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
        // Claimed up front, not on failure: if the app is quit or crashes while
        // the upload is in flight, this is the only thing left saying the
        // recording is still owed a transcript.
        record.qualityPassPending = true
        guard let pipeline = EngineFactory.processingPipeline(engine: engine) else {
            record.state = .ready
            record.qualityPassPending = true
            // Only reachable on the paid engine: the free one needs no key.
            record.processingError = L(
                "화자분리 전사를 켜뒀는데 OpenAI 키가 없어요. 설정에서 키를 넣거나, 전사 엔진을 '기기에서 (무료)'로 바꾸면 바로 처리돼요.",
                "Speaker-separated transcription is selected but there's no OpenAI key. Add one in Settings, or switch the transcription engine to \"On this device (free)\" and this runs right away.")
            try? record.modelContext?.save()
            inFlight.remove(record.directoryName)
            return
        }

        Task { @MainActor in
            // Every exit below releases the retry slot: success, empty result,
            // and failure alike. Leaking one would freeze that recording out of
            // all future retries.
            defer { inFlight.remove(record.directoryName) }
            do {
                // Names read off the meeting screen double as vocabulary hints
                // so transcription spells them right.
                let rosterNames = RosterNameMapper.participantNames(
                    in: rosterSnapshots, ownerName: ownerName)
                let output = try await pipeline.process(
                    files: files,
                    ownerName: ownerName,
                    hints: TranscriptHints(vocabulary: rosterNames, languageCodes: languageHints),
                    userNotes: (userNotes?.isEmpty == false) ? userNotes : nil)

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
                    return
                }

                // The final pass replaces live segments wholesale.
                record.segments.removeAll()
                for turn in output.transcript.turns {
                    record.segments.append(StoredSegment(
                        text: turn.text, start: turn.start, end: turn.end,
                        channel: turn.channel,
                        speakerKey: output.transcript.speakerNames[turn.speakerKey] ?? turn.speakerKey,
                        isFinal: true))
                }

                // Meet/Zoom roster → transcript names: rename diarized remote
                // speakers to the names seen on their tiles.
                if let startedAt = recordingStartedAt, !rosterSnapshots.isEmpty {
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
                record.qualityPassPending = false
                record.processingError = nil
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
        inFlight.insert(record.directoryName)
        record.processingError = nil
        run(record: record, files: files,
            userNotes: record.note?.roughMarkdown,
            ownerName: ownerName, languageHints: languageHints,
            engine: engine)
        return true
    }

    /// Sessions currently mid-retry. Without this, a launch plus a network
    /// change would upload the same audio twice and bill for it twice.
    private static var inFlight: Set<String> = []

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
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "autoEmailSummary") as? Bool ?? true
        guard enabled else { return }
        let recipient = AccountDefaults.string("summaryEmailRecipient") ?? "me@thezonebio.com"
        guard !recipient.isEmpty, let sender = ComposioEmailSender.fromArcaConfig() else { return }
        do {
            try await sender.sendSummary(to: recipient, sessionTitle: record.title,
                                         notes: notes, date: record.createdAt)
        } catch {
            record.processingError = error.localizedDescription
            try? record.modelContext?.save()
        }
        #endif
    }

    /// macOS only — writes the completed meeting note to the linked Obsidian vault.
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
            _ = try ObsidianExporter.exportSession(record, to: URL(fileURLWithPath: expanded))
        } catch {
            DebugTrace.log("obsidian auto-export failed: \(error.localizedDescription)")
        }
        #endif
    }
}
