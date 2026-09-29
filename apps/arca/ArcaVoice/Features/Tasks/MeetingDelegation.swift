import Foundation
import SwiftData
import ArcaVoiceKit

/// The meeting → "대신 처리할까요?" bridge. Once a meeting's notes land, the
/// action items that are the owner's (or nobody's) become to-dos, and ARCA
/// judges each one. Anything it can do itself shows up in 할 일 with a
/// yes/no question — on every device, without waiting for a Mac to sweep.
@MainActor
enum MeetingDelegation {
    static func plan(record: RecordingSession) {
        guard let note = record.note, let context = record.modelContext,
              let data = note.actionItemsJSON,
              var items = try? JSONDecoder().decode([MeetingNotes.ActionItem].self, from: data),
              !items.isEmpty else { return }
        BrainClient.track("action_plan_ready")
        IntentTagger.tag(note.summaryMarkdown ?? record.title, surface: "meeting")
        Analytics.content("meeting_summary", [
            "title": record.title, "minutes": Int(record.duration / 60),
            "summary": note.summaryMarkdown ?? "",
            "action_items": items.map(\.text).joined(separator: "\n"),
        ])

        let source = "meeting:\(record.directoryName)"
        let existing = (try? context.fetch(FetchDescriptor<TodoTask>(
            predicate: #Predicate { $0.sourceRaw == source }))) ?? []
        // A re-summary writes fresh items without task links; the title is
        // what keeps it from filing the same to-do twice.
        var seen = Set(existing.map(\.title))
        let summary = String((note.summaryMarkdown ?? "").prefix(1500))

        var created: [TodoTask] = []
        for i in items.indices where items[i].todoTaskUID == nil && isMine(items[i].assigneeName) {
            let item = items[i]
            guard seen.insert(item.text).inserted else { continue }
            var detail = L("회의: \(record.title)", "Meeting: \(record.title)")
            if let due = item.dueText ?? item.due?.formatted(date: .abbreviated, time: .omitted) {
                detail += L("\n마감: \(due)", "\nDue: \(due)")
            }
            if !summary.isEmpty {
                detail += L("\n\n회의 요약:\n", "\n\nMeeting summary:\n") + summary
            }
            let task = TodoTask(title: item.text, detail: detail, source: source)
            task.dueAt = item.due
            context.insert(task)
            items[i].todoTaskUID = task.uid.uuidString
            created.append(task)
        }
        guard !created.isEmpty else { return }
        note.actionItemsJSON = try? JSONEncoder().encode(items)
        record.touch()
        try? context.save()
        RelaySync.shared.scheduleSync()
        Task { @MainActor in
            for task in created {
                await TaskEngine.shared.classify(task)
                SummaryNotifier.scheduleDeadline(for: task)
                // Looking something up sends nothing anywhere — ARCA just does
                // it and says so. "대신 처리할까요?" is kept for anything outbound.
                if task.actionKind == .research {
                    BrainClient.track("auto_executed")
                    TaskEngine.shared.toss(task, approved: true)
                }
            }
        }
    }

    /// The owner's items: named after them, "me", or nobody in particular.
    /// Items another participant owns stay in the notes only.
    static func isMine(_ assignee: String?) -> Bool {
        let name = assignee?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty { return true }
        let owner = (UserDefaults.standard.string(forKey: "ownerName") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mine = ["me", "나", "저", "본인", "owner"] + (owner.isEmpty ? [] : [owner])
        if mine.contains(where: { name.caseInsensitiveCompare($0) == .orderedSame }) { return true }
        // "박민성" in the transcript, "민성" in onboarding — or the reverse.
        return owner.count >= 2 && (name.localizedCaseInsensitiveContains(owner)
                                    || owner.localizedCaseInsensitiveContains(name))
    }
}

#if DEBUG
extension MeetingDelegation {
    /// `-arcaSeedMeeting` (Debug builds only): files a short two-person
    /// meeting and runs it through the real summary → plan path, so the
    /// "대신 처리할까요?" loop can be exercised on a Simulator with no mic.
    static func seedIfRequested(context: ModelContext) {
        guard ProcessInfo.processInfo.arguments.contains("-arcaSeedMeeting"),
              let summarizer = EngineFactory.summarizer() else { return }
        let owner = UserDefaults.standard.string(forKey: "ownerName") ?? "나"
        let record = RecordingSession(title: "테스트 회의", source: .voiceMemo)
        let lines = [
            (owner, "다음 주 투자사 미팅 전에 경쟁사 Granola랑 Otter 요금제를 조사해서 정리해 둘게요."),
            ("김대표", "좋아요. 오늘 논의한 내용 정리해서 저희 팀에 후속 메일 한 통 보내주실 수 있어요?"),
            (owner, "네, 제가 오늘 안에 후속 메일 초안 써서 보낼게요."),
            ("김대표", "저는 계약서 초안을 금요일까지 검토하겠습니다."),
        ]
        for (i, line) in lines.enumerated() {
            record.segments.append(StoredSegment(
                text: line.1, start: Double(i * 8), end: Double(i * 8 + 7),
                channel: .microphone, speakerKey: line.0, isFinal: true))
        }
        record.duration = 32
        record.state = .ready
        context.insert(record)
        try? context.save()
        Task { @MainActor in
            do {
                _ = try await SessionResummarizer.resummarize(record, using: summarizer)
                plan(record: record)
            } catch {
                DebugTrace.log("seed meeting: summary failed — \(error)")
            }
        }
    }
}
#endif
