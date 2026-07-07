#if os(iOS)
import Foundation
import SwiftData
import EventKit
import UIKit
import ArcaVoiceKit

/// Turns a shared screenshot/link/text into an instant "here's what I see, want
/// me to..." moment: one Claude vision call proposes concrete actions, and the
/// view lets the user run one, add a follow-up instruction, or just chat.
@MainActor
@Observable
final class ContextEngine {
    struct Suggestion: Identifiable, Sendable {
        enum Kind: String, Sendable {
            case calendar, task, plan, note
            case replyDraft = "reply_draft"
        }
        let id = UUID()
        var label: String
        var kind: Kind
        var detail: String
        /// Kind-specific fields, all strings (dates are ISO 8601).
        /// calendar: title, startISO, endISO?, location?. task: title, detail.
        /// reply_draft: draft. plan/note: usually empty.
        var payload: [String: String]
    }

    private(set) var summary: String = ""
    private(set) var suggestions: [Suggestion] = []
    private(set) var isAnalyzing = false
    private(set) var error: String?

    private var item: SharedInbox.Item?
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private var model: String {
        UserDefaults.standard.string(forKey: "chatModel") ?? "claude-sonnet-5"
    }

    /// Reads the shared item with Claude vision (or text) and proposes actions.
    func analyze(item: SharedInbox.Item, instruction: String? = nil) async {
        self.item = item
        isAnalyzing = true
        error = nil
        defer { isAnalyzing = false }

        guard let apiKey = KeychainStore.get(.anthropic), !apiKey.isEmpty else {
            error = "Add an Anthropic key in Settings to read this."
            return
        }
        do {
            let content = try contentBlocks(for: item, instruction: instruction)
            let result = try await Self.callTool(content: content, apiKey: apiKey,
                                                  model: model, endpoint: endpoint)
            summary = result.summary
            suggestions = result.suggestions
        } catch {
            self.error = Self.friendlyMessage(for: error)
        }
    }

    /// Runs a suggested action. If `instruction` is non-empty, ARCA also
    /// answers it directly so the caller can show both results.
    @discardableResult
    func run(_ suggestion: Suggestion, context: ModelContext, instruction: String?) async -> String {
        let result = await execute(suggestion, context: context)
        let trimmed = instruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return result }
        let reply = await answerDirect(trimmed)
        return "\(result)\n\n\(reply)"
    }

    /// A quick ARCA reply to a typed instruction, grounded in the analysis
    /// summary (and the shared image, if any) — used for a direct inline answer.
    func answerDirect(_ instruction: String) async -> String {
        guard let apiKey = KeychainStore.get(.anthropic), !apiKey.isEmpty else {
            return "Add an Anthropic key in Settings to ask ARCA."
        }
        var parts: [ChatMessage.Part] = []
        if let item, item.kind == .image, let url = SharedInbox.imageURL(for: item),
           let raw = try? Data(contentsOf: url), let jpeg = Self.downscaledJPEG(from: raw) {
            parts.append(.image(jpeg))
        }
        parts.append(.text(instruction))
        let extraSystem = summary.isEmpty ? "" : "\n\nWhat's on screen: \(summary)"
        do {
            return try await ClaudeChat(apiKey: apiKey, model: model, extraSystem: extraSystem)
                .reply(to: [ChatMessage(role: .user, parts: parts)], maxTokens: 500)
        } catch {
            return "Couldn't reach ARCA: \(Self.friendlyMessage(for: error))"
        }
    }

    // MARK: - Action execution

    private func execute(_ suggestion: Suggestion, context: ModelContext) async -> String {
        switch suggestion.kind {
        case .calendar: return await addToCalendar(suggestion)
        case .task: return createTask(suggestion, context: context)
        case .plan: return await savePlan(context: context)
        case .replyDraft: return suggestion.payload["draft"] ?? suggestion.detail
        case .note: return summary.isEmpty ? suggestion.detail : summary
        }
    }

    private func addToCalendar(_ suggestion: Suggestion) async -> String {
        let store = EKEventStore()
        do {
            let granted = try await store.requestWriteOnlyAccessToEvents()
            guard granted else { return "Calendar access denied — enable it in Settings." }
        } catch {
            return "Couldn't get calendar access: \(Self.friendlyMessage(for: error))"
        }

        let title = suggestion.payload["title"] ?? suggestion.label
        let start = Self.parseISODate(suggestion.payload["startISO"]) ?? Date()
        let end = Self.parseISODate(suggestion.payload["endISO"]) ?? start.addingTimeInterval(3600)

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.location = suggestion.payload["location"]
        event.calendar = store.defaultCalendarForNewEvents
        do {
            try store.save(event, span: .thisEvent)
            let display = DateFormatter()
            display.dateStyle = .medium
            display.timeStyle = .short
            return "Added to Calendar: \(title) — \(display.string(from: start))"
        } catch {
            return "Couldn't save the event: \(Self.friendlyMessage(for: error))"
        }
    }

    private func createTask(_ suggestion: Suggestion, context: ModelContext) -> String {
        let task = TodoTask(
            title: suggestion.payload["title"] ?? suggestion.label,
            detail: suggestion.payload["detail"] ?? suggestion.detail,
            source: "context")
        context.insert(task)
        try? context.save()
        Task { await TaskEngine.shared.classify(task) }
        return "Task created"
    }

    private func savePlan(context: ModelContext) async -> String {
        guard let item else { return "Nothing to build a plan from." }
        guard let apiKey = KeychainStore.get(.anthropic), !apiKey.isEmpty else {
            return "Add an Anthropic key in Settings to build the plan."
        }
        let planner = ClaudeVisionPlanner(apiKey: apiKey, model: model)
        do {
            let plan: CapturePlan
            switch item.kind {
            case .image:
                guard let url = SharedInbox.imageURL(for: item),
                      let raw = try? Data(contentsOf: url),
                      let jpeg = Self.downscaledJPEG(from: raw) else {
                    return "Couldn't read the shared image."
                }
                plan = try await planner.plan(imageData: jpeg, mediaType: "image/jpeg")
            case .text, .url:
                plan = try await planner.planText(item.text ?? "")
            }
            let record = RecordingSession(
                title: (item.kind == .image ? "📸 " : "🔗 ") + plan.title,
                source: .screenshot)
            record.state = .ready
            let note = SessionNote()
            note.summaryMarkdown = plan.insightMarkdown
            note.actionItemsJSON = try? JSONEncoder().encode(plan.actionItems)
            record.note = note
            context.insert(record)
            try? context.save()
            return "Action plan saved to Library"
        } catch {
            return "Couldn't build the plan: \(Self.friendlyMessage(for: error))"
        }
    }

    // MARK: - Claude tool call

    private func contentBlocks(for item: SharedInbox.Item, instruction: String?) throws -> [[String: Any]] {
        var text = "Look at what's shared and propose 2-4 concrete actions I can take right now."
        if let instruction, !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += " The user also said: \"\(instruction)\""
        }
        switch item.kind {
        case .image:
            guard let url = SharedInbox.imageURL(for: item),
                  let raw = try? Data(contentsOf: url),
                  let jpeg = Self.downscaledJPEG(from: raw) else {
                throw ContextError.noImage
            }
            return [
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg",
                                              "data": jpeg.base64EncodedString()]],
                ["type": "text", "text": text],
            ]
        case .url, .text:
            return [["type": "text", "text": text + "\n\nContent:\n\(item.text ?? "")"]]
        }
    }

    private static func callTool(content: [[String: Any]], apiKey: String, model: String,
                                  endpoint: URL) async throws -> (summary: String, suggestions: [Suggestion]) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let tool: [String: Any] = [
            "name": "suggest_context_actions",
            "description": "Record what's on screen and the concrete actions ARCA can offer to take.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "summary": ["type": "string",
                                "description": "Two-line plain-English summary of what this screen or content is about"],
                    "suggestions": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "label": ["type": "string", "description": "Short button label, e.g. 'Add to Calendar'"],
                                "kind": ["type": "string", "enum": ["calendar", "task", "plan", "reply_draft", "note"]],
                                "detail": ["type": "string", "description": "One line explaining what ARCA will do if tapped"],
                                "payload": [
                                    "type": "object",
                                    "description": "Kind-specific fields. calendar: title, startISO, endISO?, location?. task: title, detail. reply_draft: draft. plan/note: usually empty.",
                                    "properties": [
                                        "title": ["type": "string"],
                                        "startISO": ["type": "string", "description": "ISO 8601 start datetime, required for calendar"],
                                        "endISO": ["type": "string", "description": "ISO 8601 end datetime, optional for calendar"],
                                        "location": ["type": "string"],
                                        "detail": ["type": "string"],
                                        "draft": ["type": "string"],
                                    ] as [String: Any],
                                ] as [String: Any],
                            ],
                            "required": ["label", "kind", "detail", "payload"],
                        ] as [String: Any],
                    ],
                ],
                "required": ["summary", "suggestions"],
            ] as [String: Any],
        ]

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1200,
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": "suggest_context_actions"],
            "messages": [["role": "user", "content": content]],
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60
        let (data, response) = try await uploadBody(URLSession.shared, for: request, body: bodyData)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? ""
            throw ContextError.api((response as? HTTPURLResponse)?.statusCode ?? 0, message)
        }
        return try parseResult(from: data)
    }

    private static func parseResult(from data: Data) throws -> (summary: String, suggestions: [Suggestion]) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let toolUse = content.first(where: { ($0["type"] as? String) == "tool_use" }),
              let input = toolUse["input"] as? [String: Any] else {
            throw ContextError.noToolUse
        }
        let summary = input["summary"] as? String ?? ""
        let rawSuggestions = input["suggestions"] as? [[String: Any]] ?? []
        let suggestions: [Suggestion] = rawSuggestions.compactMap { entry in
            guard let label = entry["label"] as? String,
                  let kindRaw = entry["kind"] as? String,
                  let kind = Suggestion.Kind(rawValue: kindRaw) else { return nil }
            let detail = entry["detail"] as? String ?? ""
            let payloadRaw = entry["payload"] as? [String: Any] ?? [:]
            var payload: [String: String] = [:]
            for (key, value) in payloadRaw {
                if let string = value as? String { payload[key] = string }
            }
            return Suggestion(label: label, kind: kind, detail: detail, payload: payload)
        }
        return (summary, suggestions)
    }

    // MARK: - Helpers

    /// Downscales to <=1600px on the long edge — shared items may still be full-res.
    private static func downscaledJPEG(from data: Data, maxDimension: CGFloat = 1600) -> Data? {
        guard let image = UIImage(data: data) else { return data }
        let size = image.size
        let scale = min(1, maxDimension / max(size.width, size.height))
        guard scale < 1 else { return image.jpegData(compressionQuality: 0.8) ?? data }
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return resized.jpegData(compressionQuality: 0.75) ?? data
    }

    private static func parseISODate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: raw)
    }

    private static func friendlyMessage(for error: Error) -> String {
        String(error.localizedDescription.prefix(140))
    }

    enum ContextError: Error, LocalizedError {
        case noImage
        case api(Int, String)
        case noToolUse

        var errorDescription: String? {
            switch self {
            case .noImage: return "Couldn't read the shared image"
            case .api(let status, let message): return "Analysis failed (HTTP \(status)): \(message)"
            case .noToolUse: return "Couldn't parse ARCA's response"
            }
        }
    }
}
#endif
