import Foundation
import ArcaVoiceCore

/// Multi-turn conversation with ARCA over the Anthropic Messages API.
/// Supports image content (screenshots the user is asking about). Uses the
/// shared `uploadBody` transport so large image turns don't stall over HTTP/2.
public struct ClaudeChat: Sendable {
    private let apiKey: String
    private let model: String
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// ARCA's voice: a screen-aware companion, concise and action-oriented.
    public static let systemPrompt = """
    You are ARCA, the user's companion. Answer in English, concisely and actionably — lead with \
    what to do next, skip preamble. When a screenshot is attached, read its text, numbers, and UI \
    accurately and ground your answer in it. If the task needs you to directly operate a browser \
    or the screen to help (opening a website, filling a form, clicking, etc.), propose it on the \
    last line of your reply in exactly this format: `[BROWSER: <one sentence describing what to \
    do>]`. Don't use that tag otherwise.
    """

    private let extraSystem: String

    public init(apiKey: String, model: String = "claude-sonnet-5", extraSystem: String = "") {
        self.apiKey = apiKey
        self.model = model
        self.extraSystem = extraSystem
    }

    /// Sends the conversation and returns ARCA's reply text.
    public func reply(to messages: [ChatMessage], maxTokens: Int = 1500) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": Self.systemPrompt + extraSystem,
            "messages": messages.map(Self.wireMessage),
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await uploadBody(URLSession.shared, for: request, body: payload)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? ""
            throw ChatError.api((response as? HTTPURLResponse)?.statusCode ?? 0, message)
        }
        AIUsageLog.recordResponse(provider: "anthropic", model: model, source: "chat", data: data)
        return try Self.parseText(from: data)
    }

    static func wireMessage(_ message: ChatMessage) -> [String: Any] {
        let content: [[String: Any]] = message.parts.map { part in
            switch part.kind {
            case .text:
                return ["type": "text", "text": part.text ?? ""]
            case .image:
                return [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": part.mediaType ?? "image/jpeg",
                        "data": (part.imageData ?? Data()).base64EncodedString(),
                    ],
                ]
            }
        }
        return ["role": message.role.rawValue, "content": content]
    }

    static func parseText(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw ChatError.badResponse
        }
        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        return text
    }

    /// Extracts a `[BROWSER: ...]` delegation request, if ARCA proposed one.
    public static func browserTask(in reply: String) -> String? {
        guard let range = reply.range(of: #"\[BROWSER:\s*(.+?)\]"#, options: .regularExpression) else {
            return nil
        }
        let match = String(reply[range])
        return match
            .replacingOccurrences(of: "[BROWSER:", with: "")
            .replacingOccurrences(of: "]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The reply text with any `[BROWSER: ...]` tag stripped for display.
    public static func stripBrowserTag(_ reply: String) -> String {
        reply.replacingOccurrences(of: #"\[BROWSER:.*?\]"#, with: "",
                                   options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public enum ChatError: Error, LocalizedError {
        case api(Int, String)
        case badResponse

        public var errorDescription: String? {
            switch self {
            case .api(let status, let message): return "Chat failed (HTTP \(status)): \(message)"
            case .badResponse: return "Couldn't parse the response"
            }
        }
    }
}
