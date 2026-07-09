import Foundation
import ArcaVoiceCore

/// Meeting-intelligence `Summarizer` backed by OpenAI.
/// Used as the resilient fallback when Anthropic is missing or out of credits.
public struct OpenAISummarizer: Summarizer {
    private let apiKey: String
    private let model: String
    private let endpoint: URL
    private let maxOutputTokens: Int
    private let urlSession: URLSession

    public init(
        apiKey: String,
        model: String = "gpt-4o-mini",
        endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!,
        maxOutputTokens: Int = 4096,
        urlSession: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.maxOutputTokens = maxOutputTokens
        self.urlSession = urlSession
    }

    public func summarize(
        _ transcript: AttributedTranscript,
        userNotes: String?,
        style: NoteStyle
    ) async throws -> MeetingNotes {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "max_output_tokens": maxOutputTokens,
            "input": [
                [
                    "role": "system",
                    "content": [
                        ["type": "input_text", "text": ClaudeSummarizer.systemPrompt(style: style)],
                    ],
                ],
                [
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": Self.userPrompt(transcript: transcript, userNotes: userNotes, style: style)],
                    ],
                ],
            ],
            "text": ["format": ["type": "json_object"]],
        ]

        let payload: Data
        do {
            payload = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw OpenAISummarizerError.encoding(error)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await uploadBody(urlSession, for: request, body: payload)
        } catch {
            throw OpenAISummarizerError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpenAISummarizerError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAISummarizerError.api(status: http.statusCode, message: Self.apiErrorMessage(from: data))
        }

        AIUsageLog.recordResponse(provider: "openai", model: model, source: "summary", data: data)
        return try Self.parseNotes(from: data, style: style, userNotes: userNotes)
    }

    static func userPrompt(transcript: AttributedTranscript, userNotes: String?, style: NoteStyle) -> String {
        let schemaHint = """
        Return only a JSON object with:
        {
          "title": string,
          "summaryMarkdown": string,
          "decisions": string[],
          "actionItems": [{"text": string, "assigneeName": string|null, "due": "YYYY-MM-DD"|null}],
          "enhancedNotesMarkdown": string|null
        }
        """
        return [ClaudeSummarizer.userPrompt(transcript: transcript, userNotes: userNotes, style: style), schemaHint]
            .joined(separator: "\n\n")
    }

    struct NotesJSON: Decodable {
        struct ActionItem: Decodable {
            var text: String
            var assigneeName: String?
            var due: String?
        }
        var title: String
        var summaryMarkdown: String
        var decisions: [String]?
        var actionItems: [ActionItem]?
        var enhancedNotesMarkdown: String?
    }

    static func parseNotes(from data: Data, style: NoteStyle, userNotes: String?) throws -> MeetingNotes {
        guard let text = try outputText(from: data), let jsonData = text.data(using: .utf8) else {
            throw OpenAISummarizerError.missingJSON
        }
        let wire: NotesJSON
        do {
            wire = try JSONDecoder().decode(NotesJSON.self, from: jsonData)
        } catch {
            throw OpenAISummarizerError.decoding(error)
        }

        let items = (wire.actionItems ?? []).map {
            MeetingNotes.ActionItem(
                text: $0.text,
                assigneeName: $0.assigneeName?.isEmpty == true ? nil : $0.assigneeName,
                due: ClaudeSummarizer.parseDate($0.due)
            )
        }

        let enhanced: String?
        if style == .enhancedNotes,
           let userNotes, !userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            enhanced = wire.enhancedNotesMarkdown
        } else {
            enhanced = nil
        }

        return MeetingNotes(
            title: wire.title,
            summaryMarkdown: wire.summaryMarkdown,
            decisions: wire.decisions ?? [],
            actionItems: items,
            enhancedNotesMarkdown: enhanced
        )
    }

    static func outputText(from data: Data) throws -> String? {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw OpenAISummarizerError.decoding(error)
        }
        guard let root = object as? [String: Any] else { return nil }
        if let direct = root["output_text"] as? String { return direct }
        guard let output = root["output"] as? [[String: Any]] else { return nil }
        for item in output {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            let text = content
                .filter { ($0["type"] as? String) == "output_text" }
                .compactMap { $0["text"] as? String }
                .joined()
            if !text.isEmpty { return text }
        }
        return nil
    }

    static func apiErrorMessage(from data: Data) -> String {
        struct ErrorEnvelope: Decodable {
            struct APIError: Decodable { var message: String? }
            var error: APIError?
        }
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
           let message = envelope.error?.message, !message.isEmpty {
            return message
        }
        if let raw = String(data: data, encoding: .utf8), !raw.isEmpty {
            return raw
        }
        return "Unknown error."
    }
}

public enum OpenAISummarizerError: Error, CustomStringConvertible, LocalizedError {
    case encoding(Error)
    case transport(Error)
    case invalidResponse
    case api(status: Int, message: String)
    case missingJSON
    case decoding(Error)

    public var description: String {
        switch self {
        case .encoding(let error):
            return "Could not encode the OpenAI summarization request: \(error.localizedDescription)"
        case .transport(let error):
            return "Network error contacting OpenAI: \(error.localizedDescription)"
        case .invalidResponse:
            return "OpenAI returned a response that was not HTTP."
        case .api(let status, let message):
            return "OpenAI summarization failed (HTTP \(status)): \(message)"
        case .missingJSON:
            return "OpenAI response did not contain structured notes JSON."
        case .decoding(let error):
            return "Could not parse the OpenAI notes JSON: \(error.localizedDescription)"
        }
    }

    public var errorDescription: String? { description }
}

public struct FallbackSummarizer: Summarizer {
    private let primary: any Summarizer
    private let fallback: any Summarizer

    public init(primary: any Summarizer, fallback: any Summarizer) {
        self.primary = primary
        self.fallback = fallback
    }

    public func summarize(
        _ transcript: AttributedTranscript,
        userNotes: String?,
        style: NoteStyle
    ) async throws -> MeetingNotes {
        do {
            return try await primary.summarize(transcript, userNotes: userNotes, style: style)
        } catch {
            return try await fallback.summarize(transcript, userNotes: userNotes, style: style)
        }
    }
}
