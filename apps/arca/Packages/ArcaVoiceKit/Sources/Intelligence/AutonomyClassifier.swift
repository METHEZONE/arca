import Foundation
import ArcaVoiceCore
import Store

/// Judges what kind of action a task needs and whether ARCA can safely run it
/// on its own. Claude classifies into a `TaskActionKind`; the app then gates on
/// the user's autonomy level. Deterministic structured output via a forced tool.
public struct AutonomyClassifier: Sendable {
    private let apiKey: String
    private let model: String
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public struct Judgment: Sendable {
        public var actionKind: TaskActionKind
        public var urgency: TaskUrgency
        public var rationale: String
        /// A concrete, self-contained instruction ARCA would follow to do it.
        public var executionPlan: String
    }

    public init(apiKey: String, model: String = "claude-sonnet-5") {
        self.apiKey = apiKey
        self.model = model
    }

    public func classify(title: String, detail: String = "") async throws -> Judgment {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let tool: [String: Any] = [
            "name": "classify_task",
            "description": "Classify how autonomously ARCA can handle a task.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "actionKind": [
                        "type": "string",
                        "enum": ["research", "draft", "send", "broad", "manual"],
                        "description": "research=read-only lookup/summary; draft=prepare a message/doc but don't send; send=send/schedule/file something; broad=multi-step or ambiguous end-to-end; manual=inherently needs the user (a personal decision, attending a meeting, creative judgment).",
                    ],
                    "urgency": [
                        "type": "string",
                        "enum": ["now", "today", "soon", "someday"],
                        "description": "When this needs to happen: now=blocking or deadline-critical, drop everything; today=should be done before the day ends; soon=this week; someday=no real time pressure. Judge from explicit deadlines, blocking language, consequences of delay, and how perishable the task is.",
                    ],
                    "rationale": ["type": "string", "description": "One-line reason for this classification, in English"],
                    "executionPlan": ["type": "string", "description": "A concrete one-to-two sentence instruction ARCA would follow if it ran this in the background, in English. If manual, describe what the user needs to decide."],
                ],
                "required": ["actionKind", "urgency", "rationale", "executionPlan"],
            ] as [String: Any],
        ]

        let userText = """
        Classify the following task. The goal is to judge whether ARCA (the user's AI companion) \
        can handle it on its own in the background, on the user's behalf. If it needs personal \
        judgment, a creative decision, or the user's direct attendance, classify it as manual.

        Title: \(title)
        \(detail.isEmpty ? "" : "Description: \(detail)")
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 500,
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": "classify_task"],
            "messages": [["role": "user", "content": [["type": "text", "text": userText]]]],
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await uploadBody(URLSession.shared, for: request, body: payload)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? ""
            throw ClassifierError.api((response as? HTTPURLResponse)?.statusCode ?? 0, message)
        }
        return try Self.parse(from: data)
    }

    static func parse(from data: Data) throws -> Judgment {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let tool = content.first(where: { ($0["type"] as? String) == "tool_use" }),
              let input = tool["input"] as? [String: Any] else {
            throw ClassifierError.badResponse
        }
        let kind = TaskActionKind(rawValue: (input["actionKind"] as? String) ?? "manual") ?? .manual
        let urgency = TaskUrgency(rawValue: (input["urgency"] as? String) ?? "soon") ?? .soon
        return Judgment(
            actionKind: kind,
            urgency: urgency,
            rationale: (input["rationale"] as? String) ?? "",
            executionPlan: (input["executionPlan"] as? String) ?? "")
    }

    public enum ClassifierError: Error, LocalizedError {
        case api(Int, String)
        case badResponse
        public var errorDescription: String? {
            switch self {
            case .api(let s, let m): return "Classification failed (HTTP \(s)): \(String(m.prefix(140)))"
            case .badResponse: return "Couldn't parse the classification response"
            }
        }
    }
}
