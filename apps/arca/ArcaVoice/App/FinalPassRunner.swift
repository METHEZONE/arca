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
        languageHints: [String]
    ) {
        guard let pipeline = EngineFactory.processingPipeline() else {
            record.state = .ready
            record.processingError = "No OpenAI API key, so only the live transcript was saved. Add a key in Settings to get high-quality diarized transcription."
            try? record.modelContext?.save()
            return
        }

        Task { @MainActor in
            do {
                let output = try await pipeline.process(
                    files: files,
                    ownerName: ownerName,
                    hints: TranscriptHints(languageCodes: languageHints),
                    userNotes: (userNotes?.isEmpty == false) ? userNotes : nil)

                // The final pass replaces live segments wholesale.
                record.segments.removeAll()
                for turn in output.transcript.turns {
                    record.segments.append(StoredSegment(
                        text: turn.text, start: turn.start, end: turn.end,
                        channel: turn.channel,
                        speakerKey: output.transcript.speakerNames[turn.speakerKey] ?? turn.speakerKey,
                        isFinal: true))
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
                record.processingError = nil
                try record.modelContext?.save()

                if let notes = output.notes {
                    await autoSendEmailIfEnabled(record: record, notes: notes)
                }
            } catch {
                record.state = .ready
                record.processingError = "High-quality pass failed: \(error.localizedDescription)"
                try? record.modelContext?.save()
            }
        }
    }

    /// Re-runs the quality pass for sessions whose last attempt failed (dead
    /// key, network, an old bug) — audio is still on disk, so a working key
    /// on the next launch heals the library.
    static func retryFailed(context: ModelContext, ownerName: String,
                            languageHints: [String]) {
        let sessions = (try? context.fetch(FetchDescriptor<RecordingSession>())) ?? []
        for record in sessions {
            guard let error = record.processingError,
                  error.contains("High-quality pass failed")
                      || error.contains("고품질 패스"),
                  !record.audioAssets.isEmpty else { continue }
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

    /// macOS only — sends the summary through the ARCA Composio Gmail connection.
    private static func autoSendEmailIfEnabled(record: RecordingSession, notes: MeetingNotes) async {
        #if os(macOS)
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "autoEmailSummary") as? Bool ?? true
        guard enabled else { return }
        let recipient = defaults.string(forKey: "summaryEmailRecipient") ?? "me@thezonebio.com"
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
}
