import Foundation
import SwiftData
import ArcaVoiceKit
#if os(macOS)
import AppKit
#endif

/// The things ARCA can actually do from a chat turn, and how each is described
/// to the model. Runs on the main actor because most of them touch SwiftData.
@MainActor
enum ChatToolbox {
    static let specs: [ClaudeToolSpec] = [
        ClaudeToolSpec(
            name: "search_memory",
            description: "Search the user's long-term memory (facts, preferences, projects, insights ARCA has learned). Use before claiming you don't know something about the user.",
            schemaJSON: #"{"type":"object","properties":{"query":{"type":"string","description":"Keywords or a short phrase; Korean or English."}},"required":["query"]}"#),
        ClaudeToolSpec(
            name: "list_meetings",
            description: "List the user's recent recorded meetings and notes (id, date, title, duration). Use to find which meeting the user means.",
            schemaJSON: #"{"type":"object","properties":{"limit":{"type":"integer","description":"How many, newest first. Default 12."},"query":{"type":"string","description":"Optional title filter."}}}"#),
        ClaudeToolSpec(
            name: "read_meeting",
            description: "Read one recorded meeting: its summary, decisions, action items, and the transcript. Use before summarizing, quoting, or answering questions about a meeting.",
            schemaJSON: #"{"type":"object","properties":{"id":{"type":"string","description":"The meeting id from list_meetings."},"include_transcript":{"type":"boolean","description":"Include the full transcript (long). Default true."}},"required":["id"]}"#),
        ClaudeToolSpec(
            name: "create_todo",
            description: "Create a to-do in the user's ARCA task list. Use when the user asks to remember, track, or hand off something.",
            schemaJSON: #"{"type":"object","properties":{"title":{"type":"string"},"detail":{"type":"string"},"due":{"type":"string","description":"ISO 8601 date or datetime, if any."}},"required":["title"]}"#),
        ClaudeToolSpec(
            name: "save_note",
            description: "Save a markdown document the user asked for (a report, a plan, a draft) as a note file. It lands in the user's Obsidian vault when one is connected, otherwise in ~/Documents/ARCA. Returns the path.",
            schemaJSON: #"{"type":"object","properties":{"title":{"type":"string"},"markdown":{"type":"string"}},"required":["title","markdown"]}"#),
        ClaudeToolSpec(
            name: "open_url",
            description: "Open a URL in the user's default browser.",
            schemaJSON: #"{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}"#),
        ClaudeToolSpec(
            name: "run_browser_task",
            description: "Delegate a multi-step task to ARCA's own browser window (find and compare things across sites, fill a form, read a page behind a login the user has done there, post in a web app). ARCA looks at screenshots and clicks/types itself; the user watches and approves risky clicks. Describe the goal, not the clicks. Slow — use for things that genuinely need a browser.",
            schemaJSON: #"{"type":"object","properties":{"task":{"type":"string","description":"One paragraph describing the outcome wanted."}},"required":["task"]}"#),
    ]

    /// Human label for a tool step while it runs.
    static func label(for name: String, inputJSON: String) -> String {
        let input = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8)) as? [String: Any]) ?? [:]
        switch name {
        case "search_memory": return L("기억 검색: \(input["query"] as? String ?? "")", "Searching memory: \(input["query"] as? String ?? "")")
        case "list_meetings": return L("회의 목록 확인", "Listing meetings")
        case "read_meeting": return L("회의 기록 읽기", "Reading a meeting")
        case "create_todo": return L("투두 만들기: \(input["title"] as? String ?? "")", "Creating to-do: \(input["title"] as? String ?? "")")
        case "save_note": return L("노트 저장: \(input["title"] as? String ?? "")", "Saving note: \(input["title"] as? String ?? "")")
        case "open_url": return L("링크 열기", "Opening link")
        case "run_browser_task": return L("브라우저 작업 실행", "Running browser task")
        case "web_search": return L("웹 검색", "Web search")
        default: return name
        }
    }

    // MARK: - Execution

    static func execute(name: String, inputJSON: String) async -> (summary: String, result: String, ok: Bool) {
        let input = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8)) as? [String: Any]) ?? [:]
        guard let context = AppServices.shared.container?.mainContext else {
            return (L("데이터베이스를 열 수 없어요", "No database"), "database unavailable", false)
        }
        switch name {
        case "search_memory":
            let query = (input["query"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let facts = (try? context.fetch(FetchDescriptor<MemoryFact>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
            let terms = query.lowercased().split(separator: " ").map(String.init)
            let hits = facts.filter { fact in
                let hay = fact.text.lowercased()
                return terms.isEmpty || terms.contains { hay.contains($0) }
            }.prefix(15)
            let lines = hits.map { "- [\($0.kindRaw)] \($0.text)" }
            return (L("기억 \(lines.count)개", "\(lines.count) memories"),
                    lines.isEmpty ? "No matching memories." : lines.joined(separator: "\n"), true)

        case "list_meetings":
            let limit = input["limit"] as? Int ?? 12
            let filter = (input["query"] as? String ?? "").lowercased()
            var descriptor = FetchDescriptor<RecordingSession>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
            descriptor.fetchLimit = 200
            let sessions = ((try? context.fetch(descriptor)) ?? [])
                .filter { filter.isEmpty || $0.title.lowercased().contains(filter) }
                .prefix(limit)
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm"
            let lines = sessions.map {
                "- id: \($0.directoryName) | \(formatter.string(from: $0.createdAt)) | \($0.title) | \(Int($0.duration / 60))min | \($0.sourceRaw)"
            }
            return (L("회의 \(lines.count)개", "\(lines.count) meetings"),
                    lines.isEmpty ? "No meetings yet." : lines.joined(separator: "\n"), true)

        case "read_meeting":
            let id = input["id"] as? String ?? ""
            let includeTranscript = input["include_transcript"] as? Bool ?? true
            var descriptor = FetchDescriptor<RecordingSession>(predicate: #Predicate { $0.directoryName == id })
            descriptor.fetchLimit = 1
            guard let session = ((try? context.fetch(descriptor)) ?? []).first else {
                return (L("회의를 못 찾았어요", "Meeting not found"), "No meeting with id \(id)", false)
            }
            var out = "# \(session.title)\n\(session.createdAt.formatted())\n\n"
            if let note = session.note {
                if let summary = note.summaryMarkdown, !summary.isEmpty { out += "## Summary\n\(summary)\n\n" }
                let decisions = MeetingNoteMarkdown.decodeDecisions(from: note.decisionsJSON)
                if !decisions.isEmpty { out += "## Decisions\n" + decisions.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
                let actions = MeetingNoteMarkdown.decodeActionItems(from: note.actionItemsJSON)
                if !actions.isEmpty { out += "## Action items\n" + actions.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
            }
            if includeTranscript {
                let transcript = SessionClipboardText.transcript(for: session)
                if !transcript.isEmpty { out += "## Transcript\n" + String(transcript.prefix(20_000)) }
            }
            return (L("「\(session.title)」 읽음", "Read “\(session.title)”"), out, true)

        case "create_todo":
            let title = (input["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return (L("제목이 없어요", "No title"), "title required", false) }
            let task = TodoTask(title: title, detail: input["detail"] as? String ?? "", actionKind: .manual, source: "chat")
            if let due = input["due"] as? String { task.dueAt = ClaudeSummarizer.parseDate(due) }
            context.insert(task)
            try? context.save()
            return (L("투두 추가: \(title)", "To-do added: \(title)"), "Created to-do \"\(title)\" (uid \(task.uid.uuidString))", true)

        case "save_note":
            let title = (input["title"] as? String ?? "note").trimmingCharacters(in: .whitespaces)
            let markdown = input["markdown"] as? String ?? ""
            do {
                let url = try saveNote(title: title, markdown: markdown)
                return (L("저장: \(url.lastPathComponent)", "Saved: \(url.lastPathComponent)"), "Saved to \(url.path)", true)
            } catch {
                return (L("저장 실패", "Save failed"), error.localizedDescription, false)
            }

        case "open_url":
            guard let raw = input["url"] as? String, let url = URL(string: raw) else {
                return (L("잘못된 URL", "Bad URL"), "invalid url", false)
            }
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #endif
            return (L("열었어요: \(url.host ?? raw)", "Opened \(url.host ?? raw)"), "Opened \(raw)", true)

        case "run_browser_task":
            let task = input["task"] as? String ?? ""
            #if os(macOS)
            var log: [String] = []
            if BrowserAgent.shared.isAvailable {
                for await line in BrowserAgent.shared.run(task: task) { log.append(line); if log.count > 400 { log.removeFirst() } }
                let result = BrowserAgent.shared.lastResult
                return (L("브라우저 작업 완료", "Browser task finished"),
                        result.isEmpty ? log.suffix(20).joined(separator: "\n") : result, true)
            } else if AsideBridge.isAvailable {
                for await line in AsideBridge.run(task: task) { log.append(line); if log.count > 400 { log.removeFirst() } }
            } else if CodexBridge.codexPath() != nil {
                for await line in CodexBridge.run(task: task) { log.append(line); if log.count > 400 { log.removeFirst() } }
            } else {
                return (L("브라우저 작업에 쓸 모델 키가 없어요", "No model key for browser tasks"), "Add an Anthropic key or invite code; aside/codex are not installed either.", false)
            }
            let tail = log.suffix(60).joined(separator: "\n")
            return (L("브라우저 작업 완료", "Browser task finished"), tail.isEmpty ? "Finished with no output." : tail, true)
            #else
            return (L("맥에서만 가능해요", "Mac only"), "Browser tasks run on the Mac.", false)
            #endif

        default:
            return (name, "Unknown tool \(name)", false)
        }
    }

    /// Notes land in the vault's ARCA/Notes folder, or ~/Documents/ARCA.
    static func saveNote(title: String, markdown: String) throws -> URL {
        let base = ArcaVault.folder(.notes)
        let day = MeetingNoteMarkdown.dayString(from: .now)
        let slug = MeetingNoteMarkdown.slugify(title)
        let url = base.appendingPathComponent("\(day) \(slug).md")
        try Data(("# \(title)\n\n" + markdown).utf8).write(to: url, options: .atomic)
        return url
    }
}
