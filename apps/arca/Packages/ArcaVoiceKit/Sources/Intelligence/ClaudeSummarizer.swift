import Foundation
import ArcaVoiceCore

/// Meeting-intelligence `Summarizer` backed by the Anthropic Messages API.
///
/// Builds a prompt from the speaker-attributed transcript (+ optional user notes
/// and a `NoteStyle`) and forces a structured response via a single tool whose
/// `input_schema` mirrors `MeetingNotes`. Forcing `tool_choice` to that tool
/// makes the response parse deterministically instead of scraping prose.
///
/// BYOK: the key is passed at init (read from the Keychain by the caller).
/// Meetings are Korean by default — the model is instructed to write notes in
/// the transcript's own language.
public struct ClaudeSummarizer: Summarizer {
    private static let toolName = "record_meeting_notes"

    private let apiKey: String
    private let model: String
    private let endpoint: URL
    private let anthropicVersion: String
    private let maxTokens: Int
    private let urlSession: URLSession

    public init(
        apiKey: String,
        model: String = "claude-sonnet-5",
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        anthropicVersion: String = "2023-06-01",
        maxTokens: Int = 4096,
        urlSession: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.anthropicVersion = anthropicVersion
        self.maxTokens = maxTokens
        self.urlSession = urlSession
    }

    public func summarize(_ transcript: AttributedTranscript, userNotes: String?, style: NoteStyle) async throws -> MeetingNotes {
        let body = Self.requestBody(
            model: model,
            maxTokens: maxTokens,
            transcript: transcript,
            userNotes: userNotes,
            style: style
        )
        let httpBody: Data
        do {
            httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw ClaudeSummarizerError.encoding(error)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        // upload(from:) — a long transcript makes a large body, which can hang
        // over HTTP/2 when sent as httpBody via data(for:).
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await uploadBody(urlSession, for: request, body: httpBody)
        } catch {
            throw ClaudeSummarizerError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeSummarizerError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClaudeSummarizerError.api(status: http.statusCode, message: Self.apiErrorMessage(from: data))
        }

        AIUsageLog.recordResponse(provider: "anthropic", model: model, source: "summary", data: data)
        return try Self.parseNotes(from: data, style: style, userNotes: userNotes)
    }

    // MARK: - Request building

    public static func requestBody(
        model: String,
        maxTokens: Int,
        transcript: AttributedTranscript,
        userNotes: String?,
        style: NoteStyle
    ) -> [String: Any] {
        [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemPrompt(style: style),
            "messages": [
                [
                    "role": "user",
                    "content": userPrompt(transcript: transcript, userNotes: userNotes, style: style),
                ]
            ],
            "tools": [toolDefinition(style: style)],
            "tool_choice": ["type": "tool", "name": toolName],
        ]
    }

    static func systemPrompt(style: NoteStyle) -> String {
        var lines = [
            "You are ARCA, a meeting-notes assistant.",
            "You receive a speaker-attributed meeting transcript and produce structured notes.",
            "Write every field in the same language the transcript is written in (Korean meetings are the norm — keep them Korean).",
            "Attribute decisions and action items to the speaker who owns them; use the speaker names exactly as they appear in the transcript.",
            "Only record action items and decisions that are actually stated. Do not invent content.",
            "Call the \(toolName) tool exactly once with your result.",
        ]
        if style == .enhancedNotes {
            lines.append("The user provided rough notes: complete and clean them up using the transcript, preserving the user's intent and structure, and return them in enhancedNotesMarkdown.")
        }
        return lines.joined(separator: "\n")
    }

    static func userPrompt(transcript: AttributedTranscript, userNotes: String?, style: NoteStyle) -> String {
        var sections: [String] = []

        let styleHint: String
        switch style {
        case .meetingSummary:
            styleHint = "Produce a concise meeting summary with decisions and action items."
        case .enhancedNotes:
            styleHint = "Enhance the user's rough notes using the transcript, and also produce decisions and action items."
        case .actionItems:
            styleHint = "Focus on extracting clear, assignable action items (plus a short summary and any decisions)."
        }
        sections.append("Task: \(styleHint)")

        if let userNotes, !userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("User's rough notes:\n\(userNotes)")
        }

        sections.append("Transcript:\n\(formatTranscript(transcript))")
        return sections.joined(separator: "\n\n")
    }

    public static func formatTranscript(_ transcript: AttributedTranscript) -> String {
        transcript.turns.map { turn in
            let name = transcript.speakerNames[turn.speakerKey] ?? turn.speakerKey
            return "\(name): \(turn.text)"
        }.joined(separator: "\n")
    }

    static func toolDefinition(style: NoteStyle) -> [String: Any] {
        var properties: [String: Any] = [
            "title": [
                "type": "string",
                "description": "A short, specific title for the meeting.",
            ],
            "summaryMarkdown": [
                "type": "string",
                "description": "A markdown summary of the meeting.",
            ],
            "decisions": [
                "type": "array",
                "description": "Concrete decisions made during the meeting.",
                "items": ["type": "string"],
            ],
            "actionItems": [
                "type": "array",
                "description": "Action items agreed in the meeting.",
                "items": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "What needs to be done."],
                        "assigneeName": ["type": "string", "description": "The person responsible, if stated. Use the speaker's name from the transcript."],
                        "due": ["type": "string", "description": "Due date as an ISO 8601 date (YYYY-MM-DD), if stated."],
                    ],
                    "required": ["text"],
                ],
            ],
        ]

        var required = ["title", "summaryMarkdown", "decisions", "actionItems"]

        if style == .enhancedNotes {
            properties["enhancedNotesMarkdown"] = [
                "type": "string",
                "description": "The user's rough notes, rewritten and completed using transcript context.",
            ]
            required.append("enhancedNotesMarkdown")
        }

        return [
            "name": toolName,
            "description": "Record the structured meeting notes.",
            "input_schema": [
                "type": "object",
                "properties": properties,
                "required": required,
            ],
        ]
    }

    // MARK: - Response parsing

    /// Wire shape of the tool input — `due` stays a string here so decoding never
    /// depends on a `Date` strategy; we parse it into `MeetingNotes` below.
    struct NotesToolInput: Decodable {
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

    public static func parseNotes(from data: Data, style: NoteStyle, userNotes: String?) throws -> MeetingNotes {
        guard let toolInput = try toolUseInput(from: data) else {
            throw ClaudeSummarizerError.missingToolUse
        }

        let inputData: Data
        do {
            inputData = try JSONSerialization.data(withJSONObject: toolInput)
        } catch {
            throw ClaudeSummarizerError.decoding(error)
        }

        let wire: NotesToolInput
        do {
            wire = try JSONDecoder().decode(NotesToolInput.self, from: inputData)
        } catch {
            throw ClaudeSummarizerError.decoding(error)
        }

        let actionItems = (wire.actionItems ?? []).map { item in
            MeetingNotes.ActionItem(
                text: item.text,
                assigneeName: item.assigneeName?.isEmpty == true ? nil : item.assigneeName,
                due: parseDate(item.due)
            )
        }

        // Only surface enhanced notes when the caller asked for that style and
        // actually supplied notes to enhance.
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
            actionItems: actionItems,
            enhancedNotesMarkdown: enhanced
        )
    }

    /// Walk the response `content` array and return the first `tool_use` block's
    /// `input` object.
    static func toolUseInput(from data: Data) throws -> [String: Any]? {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ClaudeSummarizerError.decoding(error)
        }
        guard let root = object as? [String: Any],
              let content = root["content"] as? [[String: Any]] else {
            return nil
        }
        for block in content {
            if block["type"] as? String == "tool_use",
               let input = block["input"] as? [String: Any] {
                return input
            }
        }
        return nil
    }

    public static func parseDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        // Accept full ISO 8601 timestamps and bare calendar dates.
        let isoFull = ISO8601DateFormatter()
        if let date = isoFull.date(from: string) { return date }

        let dateOnly = DateFormatter()
        dateOnly.calendar = Calendar(identifier: .gregorian)
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        dateOnly.timeZone = TimeZone(identifier: "UTC")
        dateOnly.dateFormat = "yyyy-MM-dd"
        return dateOnly.date(from: string)
    }

    public static func apiErrorMessage(from data: Data) -> String {
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

public enum ClaudeSummarizerError: Error, CustomStringConvertible, LocalizedError {
    case encoding(Error)
    case transport(Error)
    case invalidResponse
    case api(status: Int, message: String)
    case missingToolUse
    case decoding(Error)

    public var description: String {
        switch self {
        case .encoding(let error):
            return "Could not encode the summarization request: \(error.localizedDescription)"
        case .transport(let error):
            return "Network error contacting Anthropic: \(error.localizedDescription)"
        case .invalidResponse:
            return "Anthropic returned a response that was not HTTP."
        case .api(let status, let message):
            return "Anthropic summarization failed (HTTP \(status)): \(message)"
        case .missingToolUse:
            return "Anthropic response did not contain the expected structured notes."
        case .decoding(let error):
            return "Could not parse the structured notes: \(error.localizedDescription)"
        }
    }

    public var errorDescription: String? { description }
}
