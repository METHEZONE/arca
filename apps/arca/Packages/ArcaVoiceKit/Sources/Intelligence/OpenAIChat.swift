import Foundation
import ArcaVoiceCore

/// Screen-aware ARCA chat backed by OpenAI Responses API.
public struct OpenAIChat: Sendable {
    private let apiKey: String
    private let model: String
    private let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    public init(apiKey: String, model: String = "gpt-4o-mini") {
        self.apiKey = apiKey
        self.model = model
    }

    public func reply(to messages: [ChatMessage], maxTokens: Int = 1500) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "instructions": ClaudeChat.systemPrompt,
            "max_output_tokens": maxTokens,
            "input": messages.map(Self.wireMessage),
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await uploadBody(URLSession.shared, for: request, body: payload)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? ""
            throw ChatError.api((response as? HTTPURLResponse)?.statusCode ?? 0, message)
        }
        AIUsageLog.recordResponse(provider: "openai", model: model, source: "chat", data: data)
        return try Self.parseText(from: data)
    }

    static func wireMessage(_ message: ChatMessage) -> [String: Any] {
        let content: [[String: Any]] = message.parts.map { part in
            switch part.kind {
            case .text:
                return ["type": "input_text", "text": part.text ?? ""]
            case .image:
                let mediaType = part.mediaType ?? "image/jpeg"
                let base64 = (part.imageData ?? Data()).base64EncodedString()
                return ["type": "input_image", "image_url": "data:\(mediaType);base64,\(base64)"]
            }
        }
        return ["role": message.role.rawValue, "content": content]
    }

    static func parseText(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatError.badResponse
        }
        if let direct = json["output_text"] as? String { return direct }
        guard let output = json["output"] as? [[String: Any]] else {
            throw ChatError.badResponse
        }
        let text = output.compactMap { item -> String? in
            guard let content = item["content"] as? [[String: Any]] else { return nil }
            let joined = content
                .filter { ($0["type"] as? String) == "output_text" }
                .compactMap { $0["text"] as? String }
                .joined()
            return joined.isEmpty ? nil : joined
        }.joined()
        guard !text.isEmpty else { throw ChatError.badResponse }
        return text
    }

    public enum ChatError: Error, LocalizedError {
        case api(Int, String)
        case badResponse

        public var errorDescription: String? {
            switch self {
            case .api(let status, let message): return "OpenAI chat failed (HTTP \(status)): \(message)"
            case .badResponse: return "Couldn't parse the OpenAI response"
            }
        }
    }
}
