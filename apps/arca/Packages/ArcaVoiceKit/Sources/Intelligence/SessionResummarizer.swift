import Foundation
import SwiftData
import ArcaVoiceCore
import Store

/// Re-runs the summarizer over a session that is already stored.
///
/// No audio is touched and nothing is re-uploaded for transcription: the
/// transcript is rebuilt from the `StoredSegment`s already on disk (the same
/// rebuild `NotionDBAutoSync` does for its manual path) and only the notes are
/// regenerated. That is what makes it cheap enough to run over a whole library
/// after the summarizer's prompt and schema change.
@MainActor
public enum SessionResummarizer {
    /// Rebuilds the attributed transcript from stored segments.
    ///
    /// Segment `speakerKey` already holds the resolved display name once the
    /// quality pass has run, so it is used directly; a segment with no key
    /// falls back to the channel label used everywhere else ("Me"/"Other").
    public static func transcript(from record: RecordingSession) -> AttributedTranscript {
        let turns = record.segments
            .sorted { $0.start < $1.start }
            .map { segment -> SpeakerTurn in
                let channel = CaptureChannel(rawValue: segment.channelRaw) ?? .microphone
                let key = segment.speakerKey ?? (channel == .microphone ? "Me" : "Other")
                return SpeakerTurn(
                    speakerKey: key,
                    text: segment.text,
                    start: segment.start,
                    end: segment.end,
                    channel: channel)
            }
        return AttributedTranscript(turns: turns)
    }

    /// True when there is stored transcript text worth re-summarizing.
    public static func canResummarize(_ record: RecordingSession) -> Bool {
        record.segments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Regenerates this session's note in place, replacing the old one.
    @discardableResult
    public static func resummarize(
        _ record: RecordingSession,
        using summarizer: any Summarizer
    ) async throws -> MeetingNotes {
        let rebuilt = transcript(from: record)
        guard !rebuilt.turns.isEmpty else { throw ResummarizeError.noStoredTranscript }

        let rough = record.note?.roughMarkdown ?? ""
        let userNotes = rough.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : rough
        let style: NoteStyle = userNotes == nil ? .meetingSummary : .enhancedNotes
        let notes = try await summarizer.summarize(rebuilt, userNotes: userNotes, style: style)

        let note = record.note ?? SessionNote(roughMarkdown: rough)
        // Action items are rewritten wholesale, so anything the user had already
        // pushed to their todo list or calendar would come back unlinked and get
        // pushed a second time. Carry the links across by task text.
        let previousLinks = decodeActionItems(note.actionItemsJSON)
            .reduce(into: [String: MeetingNotes.ActionItem]()) { links, item in
                guard item.isLinked else { return }
                links[item.text] = item
            }
        let relinked = notes.actionItems.map { item -> MeetingNotes.ActionItem in
            guard let previous = previousLinks[item.text] else { return item }
            var carried = item
            carried.id = previous.id
            carried.todoTaskUID = previous.todoTaskUID
            carried.calendarEventID = previous.calendarEventID
            return carried
        }

        note.summaryMarkdown = notes.summaryMarkdown
        note.enhancedMarkdown = notes.enhancedNotesMarkdown ?? note.enhancedMarkdown
        note.decisionsJSON = try? JSONEncoder().encode(notes.decisions)
        note.actionItemsJSON = try? JSONEncoder().encode(relinked)
        record.note = note
        // The title is deliberately left alone: a backfill silently renaming a
        // library of past meetings is not what the user asked for.
        record.touch()
        try record.modelContext?.save()
        return notes
    }

    // MARK: - One-time bulk backfill

    public struct BackfillReport: Sendable, Equatable {
        public var regenerated: Int = 0
        /// Had a note but no stored transcript left to work from.
        public var skipped: Int = 0
        public var failures: [String] = []
    }

    /// Re-summarizes every session that already carries a note written by the
    /// old shallow schema.
    ///
    /// Sequential with a pause between sessions on purpose — a library of a
    /// hundred meetings fired concurrently would hit the provider's rate limit
    /// and stall behind retries. Each session is awaited, so the main thread is
    /// never blocked; failures are collected and the sweep keeps going.
    public static func backfillDetailedSummaries(
        context: ModelContext,
        summarizer: any Summarizer,
        throttle: Duration = .seconds(2),
        log: ((String) -> Void)? = nil
    ) async -> BackfillReport {
        var report = BackfillReport()
        let sessions = (try? context.fetch(FetchDescriptor<RecordingSession>())) ?? []
        let candidates = sessions.filter { record in
            guard let note = record.note, let summary = note.summaryMarkdown else { return false }
            return !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !candidates.isEmpty else { return report }
        log?("detailed-summary backfill: \(candidates.count) session(s) to redo")

        for record in candidates {
            guard canResummarize(record) else {
                report.skipped += 1
                log?("detailed-summary backfill: skipped \(record.directoryName) — no stored transcript")
                continue
            }
            do {
                _ = try await resummarize(record, using: summarizer)
                report.regenerated += 1
            } catch {
                report.failures.append("\(record.directoryName): \(error.localizedDescription)")
                log?("detailed-summary backfill: failed \(record.directoryName) — \(error.localizedDescription)")
            }
            try? await Task.sleep(for: throttle)
        }
        log?("detailed-summary backfill: \(report.regenerated) redone, \(report.skipped) skipped, \(report.failures.count) failed")
        return report
    }

    private static func decodeActionItems(_ data: Data?) -> [MeetingNotes.ActionItem] {
        guard let data,
              let items = try? JSONDecoder().decode([MeetingNotes.ActionItem].self, from: data) else {
            return []
        }
        return items
    }
}

public enum ResummarizeError: Error, LocalizedError {
    case noStoredTranscript

    public var errorDescription: String? {
        switch self {
        case .noStoredTranscript:
            return "이 세션에는 다시 요약할 전사 내용이 없습니다."
        }
    }
}
