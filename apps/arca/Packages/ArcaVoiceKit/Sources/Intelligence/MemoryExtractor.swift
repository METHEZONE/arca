import Foundation
import ArcaVoiceCore

/// Pulls durable facts out of a finished conversation so ARCA remembers the
/// user next time. Deterministic structured output via a forced tool; returns
/// an empty list when nothing in the exchange is worth keeping.
public struct MemoryExtractor: Sendable {
    private let apiKey: String
    private let model: String
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public struct Extracted: Sendable {
        public var text: String
        public var kind: String
    }

    public init(apiKey: String, model: String = "claude-sonnet-5") {
        self.apiKey = apiKey
        self.model = model
    }

    public func extract(fromConversation transcript: String,
                        knownFacts: [String]) async throws -> [Extracted] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let tool: [String: Any] = [
            "name": "record_memories",
            "description": "Record durable facts about the user worth remembering long-term.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "memories": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "text": ["type": "string",
                                         "description": "One self-contained fact in English, ≤ 140 chars"],
                                "kind": ["type": "string",
                                         "enum": ["user", "preference", "project", "fact"]],
                            ],
                            "required": ["text", "kind"],
                        ],
                        "description": "0-5 NEW facts. Empty if nothing durable was learned.",
                    ],
                ],
                "required": ["memories"],
            ] as [String: Any],
        ]

        let known = knownFacts.isEmpty ? "(none)" : knownFacts.joined(separator: "\n- ")
        let userText = """
        Below is a conversation between the user and their AI companion. Extract only \
        NEW durable facts worth remembering long-term (who they are, preferences, \
        ongoing projects, commitments). Skip anything transient or already known.

        Already known:
        - \(known)

        Conversation:
        \(String(transcript.prefix(6000)))
        """

        let body: [String: Any] = [
            "model": model, "max_tokens": 500,
            "tools": [tool], "tool_choice": ["type": "tool", "name": "record_memories"],
            "messages": [["role": "user", "content": [["type": "text", "text": userText]]]],
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await uploadBody(URLSession.shared, for: request, body: payload)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ExtractError.api((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let tu = content.first(where: { ($0["type"] as? String) == "tool_use" }),
              let input = tu["input"] as? [String: Any],
              let raw = input["memories"] as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { d in
            guard let text = d["text"] as? String, !text.isEmpty else { return nil }
            return Extracted(text: text, kind: (d["kind"] as? String) ?? "fact")
        }
    }

    public enum ExtractError: Error {
        case api(Int)
    }
}
