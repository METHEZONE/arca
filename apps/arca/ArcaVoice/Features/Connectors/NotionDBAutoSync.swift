#if os(macOS)
import Foundation
import SwiftData
import ArcaVoiceKit

/// macOS only — pushes a finished meeting into the linked Notion database.
///
/// macOS-only for the same reason the Obsidian export is: the Notion token lives
/// in ~/.arca/connections.json, which iOS has no access to.
///
/// Off by default. Everything else ARCA auto-runs writes to ARCA's own storage;
/// this one writes into the user's Notion workspace, so it waits to be turned on
/// and pointed at a specific database.
@MainActor
enum NotionDBAutoSync {
    static let enabledKey = "autoNotionSync"
    static let databaseKey = "notionDatabaseRef"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
    }

    /// The configured database reference (id or pasted URL), or nil.
    static var databaseReference: String? {
        let value = AccountDefaults.string(databaseKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    /// Runs after the quality pass. Silent when disabled or unconfigured;
    /// surfaces its result — and its failures — in the notch, because a sync
    /// that quietly stops is indistinguishable from one that never ran.
    static func runIfEnabled(record: RecordingSession,
                             transcript: AttributedTranscript,
                             notes: MeetingNotes?) async {
        guard isEnabled, let reference = databaseReference else { return }
        // No row creation on the automatic path: every meeting reaches here,
        // including ones with nothing to do with the database, and a stray new
        // row in the user's tracker is not something they asked for.
        await run(record: record, transcript: transcript, notes: notes,
                  reference: reference, announceNoSubject: false,
                  allowRowCreation: false)
    }

    /// The 커넥터 button path: same work, but says so even when nothing matched,
    /// since the user is watching and silence would read as a broken button.
    static func runManually(record: RecordingSession) async {
        guard let reference = databaseReference else {
            AppServices.shared.notch.showNotice(
                "Notion 데이터베이스가 설정돼 있지 않아요 — 커넥터에서 DB 주소를 넣어주세요", seconds: 8)
            return
        }
        // The user pressed the button on this specific meeting and watches the
        // result, so a genuinely new vendor may get a row here.
        await run(record: record, transcript: transcript(from: record),
                  notes: notes(from: record), reference: reference,
                  announceNoSubject: true, allowRowCreation: true)
    }

    private static func run(record: RecordingSession,
                            transcript: AttributedTranscript,
                            notes: MeetingNotes?,
                            reference: String,
                            announceNoSubject: Bool,
                            allowRowCreation: Bool) async {
        guard !transcript.turns.isEmpty else { return }
        guard let key = KeychainStore.get(.anthropic), !key.isEmpty else {
            AppServices.shared.notch.showNotice(
                "Notion 동기화에는 Anthropic 키가 필요해요 — 설정에서 넣어주세요", seconds: 8)
            return
        }
        guard let sync = NotionDBSync.fromArcaConfig(anthropicKey: key) else {
            AppServices.shared.notch.showNotice(
                "Notion 토큰이 없어요 — ~/.arca/connections.json 의 notionToken 을 채워주세요", seconds: 10)
            return
        }

        do {
            let databaseId = try NotionDBClient.databaseId(from: reference)
            let result = try await sync.run(
                databaseId: databaseId,
                transcript: transcript,
                notes: notes,
                meetingTitle: record.title,
                meetingDate: record.createdAt,
                allowRowCreation: allowRowCreation)

            switch result {
            case .synced(let outcome):
                DebugTrace.log("notion sync: \(outcome.pageId) — filled \(outcome.filledColumns), preserved \(outcome.preservedColumns), dropped \(outcome.droppedColumns)")
                AppServices.shared.notch.showNotice("노션 · \(outcome.noticeText)", seconds: 7)
            case .noSubject:
                DebugTrace.log("notion sync: transcript matched no row and proposed no new one")
                if announceNoSubject {
                    AppServices.shared.notch.showNotice(
                        "이 대화가 어느 행에 대한 건지 판단하지 못했어요 — 업체명이 언급됐는지 확인해 주세요", seconds: 8)
                }
            }
        } catch {
            DebugTrace.log("notion sync failed: \(error)")
            AppServices.shared.notch.showNotice(
                "노션 동기화 실패 — \(error.localizedDescription)", seconds: 10)
        }
    }

    // MARK: - Rebuilding inputs from a stored session

    /// The manual path has no live pipeline output, so the transcript is rebuilt
    /// from what was saved.
    static func transcript(from record: RecordingSession) -> AttributedTranscript {
        let turns = record.segments
            .sorted { $0.start < $1.start }
            .map { segment in
                SpeakerTurn(
                    speakerKey: segment.speakerKey ?? "Other",
                    text: segment.text,
                    start: segment.start,
                    end: segment.end,
                    channel: CaptureChannel(rawValue: segment.channelRaw) ?? .microphone)
            }
        return AttributedTranscript(turns: turns)
    }

    static func notes(from record: RecordingSession) -> MeetingNotes? {
        guard let note = record.note else { return nil }
        let decisions = (note.decisionsJSON.flatMap {
            try? JSONDecoder().decode([String].self, from: $0)
        }) ?? []
        let actionItems = (note.actionItemsJSON.flatMap {
            try? JSONDecoder().decode([MeetingNotes.ActionItem].self, from: $0)
        }) ?? []
        return MeetingNotes(
            title: record.title,
            summaryMarkdown: note.summaryMarkdown ?? "",
            decisions: decisions,
            actionItems: actionItems,
            enhancedNotesMarkdown: note.enhancedMarkdown)
    }
}
#endif
