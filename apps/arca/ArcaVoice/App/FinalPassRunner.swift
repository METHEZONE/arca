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
        // the pass is running, this is the only thing left saying the
        // recording is still owed a transcript.
        record.qualityPassPending = true
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
            // around them (compaction, chunk export, summarization) for the few
            // seconds iOS still grants after the app leaves the foreground.
            let grace = BackgroundGrace()
            defer { grace.end() }
            #endif
            let files = await compactRecordingFiles(record: record, files: files)
            await process(record: record, files: files, userNotes: userNotes,
                          ownerName: ownerName, languageHints: languageHints,
                          rosterSnapshots: rosterSnapshots,
                          recordingStartedAt: recordingStartedAt, engine: engine)
        }
    }

    /// The pass itself, once the audio is in its final format.
    private static func process(
        record: RecordingSession,
        files: [CaptureChannel: URL],
        userNotes: String?,
        ownerName: String,
        languageHints: [String],
        rosterSnapshots: [RosterSnapshot],
        recordingStartedAt: Date?,
        engine: TranscriptionEngine?
    ) async {
        // Nothing to transcribe if nothing was captured. A meeting recorded off
        // a virtual input (BlackHole, a Zoom/Teams audio device) is exact
        // zeros end to end; sending an hour of that to the cloud costs money
        // and comes back as hallucinated captions. Say what happened instead.
        if isDigitallySilent(files: Array(files.values), duration: record.duration) {
            record.state = .ready
            record.qualityPassPending = false
            record.processingError = Self.silentRecordingMessage
            try? record.modelContext?.save()
            DebugTrace.log("final pass: \(record.directoryName) is digital silence (\(Int(record.duration))s) — not transcribing")
            return
        }

        // The final transcript landed on an earlier try and only the notes are
        // missing (the summary call failed). Summarize what's stored rather
        // than paying to transcribe the whole meeting again.
        if engine == nil, record.segments.contains(where: \.isFinal),
           summaryPendingLeads.contains(where: { record.processingError?.hasPrefix($0) == true }),
           (record.note?.summaryMarkdown ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await summarizeStoredTranscript(record: record, ownerName: ownerName)
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
        // A pass that stays pending runs again; the user hears about the
        // summary once, not on every retry.
        let alreadyNotified = !(record.note?.summaryMarkdown ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        guard let pipeline = EngineFactory.processingPipeline(
            engine: engine, includeOnDeviceFallback: !hasUsableLive) else {
            await summarizeLiveTranscriptOnly(record: record, ownerName: ownerName)
            return
        }

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
            if let attributionError = output.attributionError {
                DebugTrace.log("speakers: attribution skipped — \(attributionError)")
            }
            if output.transcriptSource == .liveSegments, output.speakersAttributed {
                applySpeakerNames(output.transcript.turns.map(\.speakerKey), to: record)
            }
            if output.transcriptSource == .finalPass {
                // Only the channels that came back are replaced. A channel
                // that failed keeps its on-device text until a retry lands.
                let produced = Set(output.transcript.turns.map { $0.channel.rawValue })
                record.segments.removeAll { produced.contains($0.channelRaw) }
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
                applyTitle(notes.title, to: record)
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
            if let summaryError = output.summaryError {
                record.qualityPassPending = true
                record.processingError = summaryPendingMessage(summaryError)
                DebugTrace.log("final pass: transcript kept, summary owed — \(summaryError)")
            }
            // Relay merge is last-writer-wins on `updatedAt`, and the pass
            // just rewrote the transcript and the notes. Without this bump
            // the improved version loses the comparison against the other
            // device's older copy and silently never propagates — the
            // recording looks fine here and stays rough over there.
            record.touch()
            try record.modelContext?.save()
            BrainClient.track("transcript_ready")

            if let notes = output.notes {
                CompanionProgress.shared.award(.meetingSummarized)
                if !alreadyNotified {
                    SummaryNotifier.summaryReady(record: record, notes: notes)
                }
                MeetingDelegation.plan(record: record)
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

    // MARK: - Audio compaction

    /// Re-encodes crash-safe CAF recordings into m4a before anything reads them.
    ///
    /// The order is what makes this safe: the m4a is verified by
    /// `AudioFinalizer`, the row is pointed at it and saved, and only then is
    /// the CAF deleted. A kill at any step leaves the CAF referenced or on disk,
    /// and the next pass simply does it again. A failure keeps the CAF — every
    /// transcriber reads it fine; it's only bigger.
    private static func compactRecordingFiles(record: RecordingSession,
                                              files: [CaptureChannel: URL]) async -> [CaptureChannel: URL] {
        var result = files
        for (channel, caf) in files where AudioFinalizer.isRecordingFile(caf) {
            let compacted: URL
            do {
                compacted = try await Task.detached(priority: .userInitiated) {
                    try AudioFinalizer.compact(caf)
                }.value
            } catch {
                DebugTrace.log("final pass: kept \(caf.lastPathComponent) uncompacted — \(error.localizedDescription)")
                continue
            }
            let seconds = AudioFinalizer.duration(of: compacted)
            let newPath = "\(record.directoryName)/\(compacted.lastPathComponent)"
            let asset = record.audioAssets.first { $0.channel == channel }
            let previousPath = asset?.relativePath
            if let asset {
                asset.relativePath = newPath
                asset.duration = seconds
            } else {
                record.audioAssets.append(AudioAsset(channel: channel, relativePath: newPath, duration: seconds))
            }
            // A recording recovered after a kill has no duration of its own yet.
            if seconds > record.duration { record.duration = seconds }
            do {
                try record.modelContext?.save()
            } catch {
                if let asset, let previousPath {
                    asset.relativePath = previousPath
                } else {
                    record.audioAssets.removeAll { $0.relativePath == newPath }
                }
                DebugTrace.log("final pass: couldn't record the compacted file — keeping the CAF (\(error))")
                continue
            }
            try? FileManager.default.removeItem(at: caf)
            result[channel] = compacted
        }
        return result
    }

    /// Finishes compaction for recordings that aren't owed a pass but still
    /// hold a CAF — a compaction that failed once, or a kill between saving the
    /// m4a and deleting the CAF. Runs with the launch sweep.
    static func compactLeftoverRecordings(context: ModelContext) {
        let sessions = (try? context.fetch(FetchDescriptor<RecordingSession>())) ?? []
        for record in sessions where record.state != .recording && record.state != .processing
            && !record.qualityPassPending && !inFlight.contains(record.directoryName) {
            let directory = SessionPaths.directory(for: record.directoryName)
            let cafs = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter(AudioFinalizer.isRecordingFile)
            guard !cafs.isEmpty else { continue }
            var toCompact: [CaptureChannel: URL] = [:]
            for caf in cafs {
                let cafPath = "\(record.directoryName)/\(caf.lastPathComponent)"
                let m4aPath = "\(record.directoryName)/\(AudioFinalizer.compactedURL(for: caf).lastPathComponent)"
                if record.audioAssets.contains(where: { $0.relativePath == cafPath }) {
                    let channel = CaptureChannel(rawValue: caf.deletingPathExtension().lastPathComponent) ?? .mixed
                    toCompact[channel] = caf
                } else if record.audioAssets.contains(where: { $0.relativePath == m4aPath }),
                          FileManager.default.fileExists(atPath: SessionPaths.resolve(relativePath: m4aPath).path) {
                    // The row already points at a verified m4a: this CAF is the
                    // leftover of a kill right before its deletion.
                    try? FileManager.default.removeItem(at: caf)
                }
            }
            guard !toCompact.isEmpty else { continue }
            inFlight.insert(record.directoryName)
            Task { @MainActor in
                defer { inFlight.remove(record.directoryName) }
                _ = await compactRecordingFiles(record: record, files: toCompact)
            }
        }
    }

    // MARK: - Notes

    /// Both languages: the error was written in whichever one was active then.
    private static let summaryPendingLeads = ["받아쓰기는 끝났고 요약만 아직이에요", "The transcript is done; only the summary"]

    private static func summaryPendingMessage(_ reason: String) -> String {
        L("받아쓰기는 끝났고 요약만 아직이에요 (\(reason)). 자동으로 다시 시도해요.",
          "The transcript is done; only the summary is still pending (\(reason)). ARCA retries automatically.")
    }

    /// Writes the notes for a transcript that's already stored.
    private static func summarizeStoredTranscript(record: RecordingSession, ownerName: String) async {
        record.state = .ready
        guard let summarizer = EngineFactory.summarizer() else {
            try? record.modelContext?.save()
            return
        }
        await attributeStoredSpeakers(record, ownerName: ownerName)
        do {
            let notes = try await SessionResummarizer.resummarize(record, using: summarizer)
            applyTitle(notes.title, to: record)
            record.qualityPassPending = false
            record.processingError = nil
            record.touch()
            try? record.modelContext?.save()
            BrainClient.track("transcript_ready")
            CompanionProgress.shared.award(.meetingSummarized)
            SummaryNotifier.summaryReady(record: record, notes: notes)
            MeetingDelegation.plan(record: record)
            await rememberFromMeeting(record: record, notes: notes)
        } catch {
            record.qualityPassPending = true
            record.processingError = summaryPendingMessage(error.localizedDescription)
            try? record.modelContext?.save()
        }
    }

    // MARK: - Speakers

    /// Writes one speaker name per stored segment, in transcript order.
    private static func applySpeakerNames(_ names: [String], to record: RecordingSession) {
        let segments = SessionResummarizer.orderedSegments(record)
        guard names.count == segments.count else {
            DebugTrace.log("speakers: \(names.count) names for \(segments.count) segments — not applied")
            return
        }
        for (segment, name) in zip(segments, names) { segment.speakerKey = name }
        record.touch()
        try? record.modelContext?.save()
    }

    /// Names the speakers of a stored live transcript that has none yet, so the
    /// summary and the "대신 처리할까요?" plan know whose action items are whose.
    private static func attributeStoredSpeakers(_ record: RecordingSession, ownerName: String) async {
        let segments = SessionResummarizer.orderedSegments(record)
        guard segments.count >= 2, segments.allSatisfy({ $0.speakerKey == nil }),
              let attributor = EngineFactory.speakerAttributor() else { return }
        let transcript = SessionResummarizer.transcript(from: record)
        do {
            let names = try await attributor.speakers(
                for: transcript,
                context: SpeakerContext(ownerName: ownerName, participants: record.participants.map(\.name)))
            applySpeakerNames(names, to: record)
        } catch {
            DebugTrace.log("speakers: attribution skipped for \(record.directoryName) — \(error.localizedDescription)")
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
    /// An empty or inaudible recording comes back titled "<UNKNOWN>" — keep
    /// the dated default instead.
    private static func applyTitle(_ raw: String, to record: RecordingSession) {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholder = (title.hasPrefix("<") && title.hasSuffix(">"))
            || ["unknown", "untitled", "제목 없음"].contains(title.lowercased())
        if !title.isEmpty, !placeholder { record.title = title }
    }

    private static func summarizeLiveTranscriptOnly(record: RecordingSession, ownerName: String) async {
        // The free engine's normal path, not a fallback: the on-device live
        // pass already is the transcript, so summarizing it is the whole job.
        // It used to fall through to the "no OpenAI key" wording below — every
        // phone recording showed an orange key warning, never got a title, and
        // stayed pending so the sweep re-ran it forever.
        if EngineFactory.transcriptionEngine == .localFree {
            record.state = .ready
            record.qualityPassPending = false
            record.processingError = nil
            try? record.modelContext?.save()
            let alreadySummarized = !(record.note?.summaryMarkdown ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard !alreadySummarized, SessionResummarizer.canResummarize(record) else { return }
            guard let summarizer = EngineFactory.summarizer() else {
                // Only a failed enroll gets here; the next sweep heals it.
                record.qualityPassPending = true
                try? record.modelContext?.save()
                return
            }
            await attributeStoredSpeakers(record, ownerName: ownerName)
            do {
                let notes = try await SessionResummarizer.resummarize(record, using: summarizer)
                applyTitle(notes.title, to: record)
                record.touch()
                try? record.modelContext?.save()
                BrainClient.track("transcript_ready")
                CompanionProgress.shared.award(.meetingSummarized)
                SummaryNotifier.summaryReady(record: record, notes: notes)
                MeetingDelegation.plan(record: record)
                await rememberFromMeeting(record: record, notes: notes)
            } catch {
                // Keep it owed: a network blip mustn't leave it unsummarized.
                record.qualityPassPending = true
                try? record.modelContext?.save()
                DebugTrace.log("final pass: live-transcript summary failed — \(error)")
            }
            return
        }
        record.state = .ready
        // Pending on purpose: coming online (or adding a key) later heals the
        // session on the next sweep.
        record.qualityPassPending = true
        let alreadySummarized = !(record.note?.summaryMarkdown ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard let summarizer = EngineFactory.summarizer(),
              SessionResummarizer.canResummarize(record),
              !alreadySummarized else {
            record.processingError = L(
                "클라우드 전사에 연결하지 못했어요. 인터넷이 연결되면 자동으로 다시 시도해요. 급하면 설정에서 전사 엔진을 '기기에서 (무료)'로 바꿀 수 있어요.",
                "Couldn't reach cloud transcription. ARCA retries automatically once you're online, or switch the transcription engine to \"On this device (free)\" in Settings.")
            try? record.modelContext?.save()
            return
        }
        record.processingError = L(
            "클라우드 전사 대신 실시간 전사로 먼저 요약했어요. 연결되면 더 정확한 전사로 다시 시도해요.",
            "Summarized the live transcript for now. ARCA retries with the more accurate cloud transcript once it can.")
        try? record.modelContext?.save()
        await attributeStoredSpeakers(record, ownerName: ownerName)
        do {
            let notes = try await SessionResummarizer.resummarize(record, using: summarizer)
            applyTitle(notes.title, to: record)
            try? record.modelContext?.save()
            BrainClient.track("transcript_ready")
            SummaryNotifier.summaryReady(record: record, notes: notes)
            MeetingDelegation.plan(record: record)
        } catch {
            DebugTrace.log("final pass: live-transcript summary failed — \(error)")
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
            // `qualityPassPending` too: it's what orphan recovery sets on a
            // recording revived after a kill, and this runs right after that
            // recovery at launch. Without it the revived recording waited for
            // the next network change before anything transcribed it.
            guard record.qualityPassPending || SessionRecovery.needsFinalPass(
                state: record.state,
                processingError: record.processingError,
                hasAudio: !record.audioAssets.isEmpty) else { continue }
            retry(record: record, ownerName: ownerName, languageHints: languageHints)
        }
    }

    /// Re-runs the pass for one recording. Returns false when there's nothing to
    /// work with (already running, no audio left on this device), so a button
    /// can stay honest about whether it did anything.
    /// Automatic attempts per session this launch, and when the last began.
    /// Sweeps fire on every foreground; a recording that keeps failing must
    /// not re-upload the whole meeting each time the user opens the app.
    private static var attempts: [String: (count: Int, last: Date)] = [:]

    /// 1, 2, 4 … minutes between automatic retries, capped at an hour.
    static func retryDelay(afterAttempts count: Int) -> TimeInterval {
        count == 0 ? 0 : min(3600, 60 * pow(2, Double(count - 1)))
    }

    @discardableResult
    static func retry(record: RecordingSession, ownerName: String,
                      languageHints: [String],
                      engine: TranscriptionEngine? = nil,
                      userInitiated: Bool = false) -> Bool {
        guard record.state != .recording, record.state != .processing,
              !record.audioAssets.isEmpty,
              record.directoryName != AppServices.shared.coordinator.activeDirectoryName,
              !inFlight.contains(record.directoryName) else { return false }
        let previous = attempts[record.directoryName]
        if !userInitiated, engine == nil, let previous,
           Date.now.timeIntervalSince(previous.last) < retryDelay(afterAttempts: previous.count) {
            return false
        }
        attempts[record.directoryName] = ((previous?.count ?? 0) + 1, .now)
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
        let urls = record.audioAssets.map { SessionPaths.resolve(relativePath: $0.relativePath) }
        let hasBytes = urls.contains { fileSize($0) > 4096 }
        return hasBytes && !isDigitallySilent(files: urls, duration: record.duration)
    }

    static let silentRecordingMessage = L(
        "녹음에 소리가 전혀 들어오지 않았어요. 맥의 입력 장치가 가상 장치(BlackHole·Zoom/Teams 오디오 등)로 잡혀 있었을 가능성이 커요 — 시스템 설정 › 사운드 › 입력을 확인해주세요. 이 녹음은 복구할 수 없어요.",
        "No sound reached this recording. The Mac's input device was most likely a virtual one (BlackHole, a Zoom/Teams audio device) — check System Settings › Sound › Input. This recording can't be recovered.")

    /// Recordings that are exact digital zeros on every channel.
    ///
    /// No decoding needed: AAC spends ~2–3 kbps on pure silence against the
    /// ~40 kbps the writer targets per channel, so bits-per-second alone
    /// separates "nothing was captured" from "quiet room" by an order of
    /// magnitude. (Three silent meetings this week measured 2.2–3.1 kbps;
    /// the quietest real one, 105 kbps.)
    static func isDigitallySilent(files: [URL], duration: TimeInterval) -> Bool {
        guard duration > 2 else { return false }
        let sizes = files.map(fileSize).filter { $0 > 0 }
        guard !sizes.isEmpty else { return false }
        return sizes.allSatisfy { Double($0) * 8 / duration < 8_000 }
    }

    /// A finished session whose audio is digital silence (and whose live pass,
    /// at most, hallucinated a few captions over it).
    static func isDigitallySilent(_ record: RecordingSession) -> Bool {
        guard record.state != .recording, record.state != .processing,
              record.segments.count <= 4 else { return false }
        let urls = record.audioAssets.map { SessionPaths.resolve(relativePath: $0.relativePath) }
        return urls.contains { fileSize($0) > 4096 }
            && isDigitallySilent(files: urls, duration: record.duration)
    }

    /// Relabels sessions recorded before the silence check existed, so their
    /// detail view says "nothing was captured" instead of "no speech found".
    /// Cheap (file attributes only for sessions with ≤4 segments); rides the
    /// Mac heartbeat.
    static func markSilentRecordings(context: ModelContext) {
        let sessions = (try? context.fetch(FetchDescriptor<RecordingSession>())) ?? []
        var changed = false
        for record in sessions where isDigitallySilent(record) && record.processingError != silentRecordingMessage {
            record.processingError = silentRecordingMessage
            record.qualityPassPending = false
            changed = true
        }
        if changed { try? context.save() }
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
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
                     languageHints: languageHints, engine: engine, userInitiated: true) {
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
        let recipient = AccountDefaults.string("summaryEmailRecipient") ?? ""
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
        BrainClient.track("meeting_captured")
        DebugTrace.log("meeting memories: \(extracted.count) from \(record.directoryName)")
        var done = Set(UserDefaults.standard.stringArray(forKey: extractedKey) ?? [])
        done.insert(record.directoryName)
        UserDefaults.standard.set(Array(done), forKey: extractedKey)
    }

    private static var extractedKey: String { "meetingMemoryExtracted.\(AccountStore.currentAccountId())" }

    /// Meetings that predate meeting→memory extraction, or that arrived over
    /// the relay (which carries no memories), are distilled a few per
    /// heartbeat until every summarized meeting has been read once. This is
    /// why a fresh account with 160 synced sessions showed "기억 0개".
    static func backfillMemoriesIfNeeded(context: ModelContext, batch: Int = 4) async {
        guard ArcaCloud.anthropicKey?.isEmpty == false else { return }
        var done = Set(UserDefaults.standard.stringArray(forKey: extractedKey) ?? [])
        let descriptor = FetchDescriptor<RecordingSession>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let pending = ((try? context.fetch(descriptor)) ?? []).filter {
            !done.contains($0.directoryName) && $0.note?.summaryMarkdown?.isEmpty == false
        }
        guard !pending.isEmpty else { return }
        for record in pending.prefix(batch) {
            guard let note = record.note, let summary = note.summaryMarkdown else { continue }
            let notes = MeetingNotes(
                title: record.title, summaryMarkdown: summary,
                decisions: MeetingNoteMarkdown.decodeDecisions(from: note.decisionsJSON),
                actionItems: MeetingNoteMarkdown.decodeActionItems(from: note.actionItemsJSON)
                    .map { MeetingNotes.ActionItem(text: $0) })
            await rememberFromMeeting(record: record, notes: notes)
            done.insert(record.directoryName)
            UserDefaults.standard.set(Array(done), forKey: extractedKey)
        }
        DebugTrace.log("memory backfill: \(min(batch, pending.count)) meetings, \(max(0, pending.count - batch)) left")
    }
}
