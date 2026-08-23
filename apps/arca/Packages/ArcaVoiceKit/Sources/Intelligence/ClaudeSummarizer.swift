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
        // A 90-minute meeting needs room for per-topic sections, quotes and
        // rationale; 4096 was the reason summaries came back as one paragraph.
        // Kept well under the model's 128K output ceiling because this request
        // is not streamed — a larger budget risks an HTTP timeout, not a bill.
        maxTokens: Int = 16000,
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

    public static func systemPrompt(style: NoteStyle) -> String {
        var lines = [
            "You are ARCA, a meeting-notes assistant. You produce the detailed record a participant would still find useful a week later.",

            "TRANSCRIPT FORMAT",
            "Every line is `[HH:MM:SS] <speaker>: <text>`, ordered by time. Use those timestamps to anchor your sections.",

            "WHO IS SPEAKING",
            "Speaker labels come from AUDIO CHANNELS, not from real speaker recognition. `Me` is the device owner's microphone. `Other`, `Other(S1)`, `Other(S2)` … are everything captured from system audio — one such label can cover several different people in the same room or on the same call.",
            "So never turn a channel label into a person's name. Use a real name only when it is actually spoken in the transcript text — if someone says \"정민아 이것 좀 봐줘\", then 정민 is a real, captured name and you may use it. Otherwise write \"나(마이크)\" for the microphone channel, \"상대방(시스템 오디오)\" for system audio, or \"미상\" when it is genuinely undeterminable. Never fabricate a name.",

            "WHAT DETAIL MEANS — THIS IS THE POINT OF THE TASK",
            "Preserve every specific number, percentage, price, date, technical term, indicator name, product name, company name, tool name and proper noun that was spoken, and write it into the notes as it was said.",
            "Generic paraphrase over specifics is a failure. \"보조지표를 논의함\" is wrong when the transcript names RSI, MACD or 이동평균선 — those names must appear. Do the same for strategies, thresholds, fee rates, deadlines and product names.",
            "Do not compress the meeting. A long meeting covers many subjects; give each subject its own topic entry instead of one blended paragraph.",
            "Never invent content. Recording less than was said is acceptable; inventing anything is not.",

            "WHAT TO PRODUCE",
            "topics: one entry per subject actually discussed, in the order it came up. `timeRange` comes from the [HH:MM:SS] stamps that bound that stretch (e.g. \"00:12:40–00:31:05\"). `keyPoints` carry the specifics. `quotes` holds 1–3 short verbatim or near-verbatim lines, and only when they materially support the point.",
            "decisions: what was decided, the rationale that was actually stated for it, and who decided or proposed it when that is determinable from the words in the transcript (\"미상\" otherwise).",
            "actionItems: the task, an owner, and a deadline. Owner: a spoken name when one was captured, otherwise the channel label, otherwise \"미정\". Deadline: an ISO date (YYYY-MM-DD) when a calendar date was stated, otherwise the deadline exactly as it was said (\"다음 주 화요일\"), otherwise literally \"미정\" — never leave it blank.",
            "openQuestions: questions and follow-ups that were raised but left unresolved in this meeting.",
            "summaryMarkdown: a substantial overview of what the meeting was about and where it landed — several sentences, not one. The per-topic detail is appended after it automatically, so do not restate the topic sections here.",

            "Write every field in the same language the transcript is written in (Korean meetings are the norm — keep them Korean).",
            "Call the \(toolName) tool exactly once with your result.",
        ]
        if style == .enhancedNotes {
            lines.append("The user provided rough notes: complete and clean them up using the transcript, preserving the user's intent and structure, and return them in enhancedNotesMarkdown.")
        }
        return lines.joined(separator: "\n")
    }

    public static func userPrompt(transcript: AttributedTranscript, userNotes: String?, style: NoteStyle) -> String {
        var sections: [String] = []

        let styleHint: String
        switch style {
        case .meetingSummary:
            styleHint = "Produce a thorough, time-anchored record of this meeting: per-topic sections with time ranges and the specifics that were said, decisions with their rationale, action items with owner and deadline, and any open questions."
        case .enhancedNotes:
            styleHint = "Enhance the user's rough notes using the transcript, and also produce the full time-anchored topic breakdown, decisions with rationale, action items with owner and deadline, and open questions."
        case .actionItems:
            styleHint = "Focus on extracting clear, assignable action items with owner and deadline — plus the topic breakdown, decisions with rationale, and open questions."
        }
        sections.append("Task: \(styleHint)")

        if let userNotes, !userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("User's rough notes:\n\(userNotes)")
        }

        sections.append("Transcript:\n\(formatTranscript(transcript))")
        return sections.joined(separator: "\n\n")
    }

    /// `[HH:MM:SS] <speaker>: <text>`, time-ordered.
    ///
    /// The timestamp is what makes a per-topic time range possible at all — the
    /// old format dropped `turn.start`, so the model had no way to anchor
    /// anything even when asked to.
    public static func formatTranscript(_ transcript: AttributedTranscript) -> String {
        transcript.turns
            .sorted { $0.start < $1.start }
            .map { turn in
                "[\(timecode(turn.start))] \(speakerLabel(for: turn, in: transcript)): \(turn.text)"
            }
            .joined(separator: "\n")
    }

    public static func timecode(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// The label shown for a turn, using the same "Me"/"Other" vocabulary as the
    /// transcript export (`RecordingSession.exportSpeakerName`).
    ///
    /// A resolved name wins. Failing that, a `"<channel>:<diarizationLabel>"`
    /// key is a channel artefact, not a name, so it renders as the channel —
    /// keeping the diarization tag (`Other(S1)`, `Other(S2)`) so distinct remote
    /// voices stay distinguishable. A bare key is already a display name: that
    /// is how stored segments carry the resolved speaker.
    public static func speakerLabel(for turn: SpeakerTurn, in transcript: AttributedTranscript) -> String {
        if let name = transcript.speakerNames[turn.speakerKey], !name.isEmpty { return name }
        if let colon = turn.speakerKey.firstIndex(of: ":") {
            if turn.channel == .microphone { return "Me" }
            let tag = String(turn.speakerKey[turn.speakerKey.index(after: colon)...])
            return tag.isEmpty ? "Other" : "Other(\(tag))"
        }
        if turn.speakerKey.isEmpty {
            return turn.channel == .microphone ? "Me" : "Other"
        }
        return turn.speakerKey
    }

    static func toolDefinition(style: NoteStyle) -> [String: Any] {
        var properties: [String: Any] = [
            "title": [
                "type": "string",
                "description": "A short, specific title for the meeting.",
            ],
            "summaryMarkdown": [
                "type": "string",
                "description": "A substantial markdown overview of what the meeting was about and where it landed. Several sentences, not one. Do not restate the per-topic sections here.",
            ],
            "topics": [
                "type": "array",
                "description": "One entry per subject actually discussed, in the order it came up. Long meetings have many.",
                "items": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "Short, specific topic title naming the actual subject."],
                        "timeRange": ["type": "string", "description": "Span of this topic from the transcript timestamps, e.g. \"00:12:40–00:31:05\"."],
                        "keyPoints": [
                            "type": "array",
                            "description": "What was said, keeping every number, technical term, indicator name and proper noun that was spoken.",
                            "items": ["type": "string"],
                        ],
                        "quotes": [
                            "type": "array",
                            "description": "1–3 short verbatim or near-verbatim lines, only when they materially support the point.",
                            "items": ["type": "string"],
                        ],
                    ],
                    "required": ["title", "timeRange", "keyPoints"],
                ],
            ],
            "decisions": [
                "type": "array",
                "description": "Concrete decisions made during the meeting.",
                "items": [
                    "type": "object",
                    "properties": [
                        "decision": ["type": "string", "description": "What was decided."],
                        "rationale": ["type": "string", "description": "The rationale actually stated for it. \"미상\" if none was given."],
                        "decidedBy": ["type": "string", "description": "Who decided or proposed it, when determinable from the transcript's own words. \"미상\" otherwise — never fabricate a name."],
                    ],
                    "required": ["decision", "rationale", "decidedBy"],
                ],
            ],
            "actionItems": [
                "type": "array",
                "description": "Action items agreed in the meeting.",
                "items": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "What needs to be done."],
                        "assigneeName": ["type": "string", "description": "The owner: a name spoken in the transcript, otherwise the channel label (\"나(마이크)\" / \"상대방(시스템 오디오)\"), otherwise \"미정\"."],
                        "due": ["type": "string", "description": "An ISO 8601 date (YYYY-MM-DD) when a calendar date was stated, otherwise the deadline exactly as it was said (\"다음 주 화요일\"), otherwise literally \"미정\". Never leave this blank."],
                    ],
                    "required": ["text", "assigneeName", "due"],
                ],
            ],
            "openQuestions": [
                "type": "array",
                "description": "Questions and follow-ups raised but left unresolved in this meeting.",
                "items": ["type": "string"],
            ],
        ]

        var required = ["title", "summaryMarkdown", "topics", "decisions", "actionItems", "openQuestions"]

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
        struct Topic: Decodable {
            var title: String
            var timeRange: String?
            var keyPoints: [String]?
            var quotes: [String]?
        }
        /// Accepts either the current object form or a bare string, so a note
        /// generated before the schema widened — or a JSON-mode model that
        /// reverts to strings — still parses.
        struct Decision: Decodable {
            var decision: String
            var rationale: String?
            var decidedBy: String?

            init(from decoder: Decoder) throws {
                if let text = try? decoder.singleValueContainer().decode(String.self) {
                    decision = text
                    return
                }
                enum Key: String, CodingKey { case decision, rationale, decidedBy }
                let container = try decoder.container(keyedBy: Key.self)
                decision = try container.decode(String.self, forKey: .decision)
                rationale = try container.decodeIfPresent(String.self, forKey: .rationale)
                decidedBy = try container.decodeIfPresent(String.self, forKey: .decidedBy)
            }
        }
        var title: String
        var summaryMarkdown: String
        var topics: [Topic]?
        var decisions: [Decision]?
        var actionItems: [ActionItem]?
        var openQuestions: [String]?
        var enhancedNotesMarkdown: String?
    }

    /// Maps the wire shape onto `MeetingNotes`, folding the topic detail and the
    /// open questions into `summaryMarkdown` so every existing reader sees them.
    static func notes(from wire: NotesToolInput, style: NoteStyle, userNotes: String?) -> MeetingNotes {
        let topics = (wire.topics ?? []).map { topic in
            MeetingNotes.Topic(
                title: topic.title,
                timeRange: topic.timeRange ?? "",
                keyPoints: topic.keyPoints ?? [],
                quotes: topic.quotes ?? []
            )
        }
        let decisionDetails = (wire.decisions ?? []).map { decision in
            MeetingNotes.Decision(
                decision: decision.decision,
                rationale: blankToNil(decision.rationale),
                decidedBy: blankToNil(decision.decidedBy)
            )
        }
        let openQuestions = (wire.openQuestions ?? []).filter { !$0.isEmpty }
        let actionItems = (wire.actionItems ?? []).map { item in
            // A deadline that isn't a calendar date used to be thrown away by
            // `parseDate`; keep the stated text alongside it.
            let parsed = parseDate(item.due)
            return MeetingNotes.ActionItem(
                text: item.text,
                assigneeName: blankToNil(item.assigneeName),
                due: parsed,
                dueText: parsed == nil ? blankToNil(item.due) : nil
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
            summaryMarkdown: MeetingNotes.composeSummaryMarkdown(
                overview: wire.summaryMarkdown, topics: topics, openQuestions: openQuestions),
            decisions: decisionDetails.map(\.line),
            actionItems: actionItems,
            enhancedNotesMarkdown: enhanced,
            topics: topics,
            decisionDetails: decisionDetails,
            openQuestions: openQuestions
        )
    }

    /// The prompt asks for an explicit "미상"/"미정" rather than a blank when
    /// something is undeterminable — that keeps the model from quietly dropping
    /// the field, but the literal placeholder is noise once it reaches the note
    /// ("근거: 미상"). Fold both forms back to nil; every renderer already has
    /// its own 미지정/미정 fallback.
    static let unknownPlaceholders: Set<String> = [
        "미상", "미정", "미확정", "없음", "해당 없음", "n/a", "na", "unknown", "none", "tbd",
    ]

    static func blankToNil(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !unknownPlaceholders.contains(trimmed.lowercased()) else { return nil }
        return trimmed
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

        return notes(from: wire, style: style, userNotes: userNotes)
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
