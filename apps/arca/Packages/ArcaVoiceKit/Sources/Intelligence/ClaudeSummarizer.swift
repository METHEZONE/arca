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
        endpoint: URL = ArcaCloud.anthropicMessagesURL,
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
            "You are ARCA, a meeting-intelligence assistant. You turn a speaker-attributed transcript into the report a busy person actually wants: whether or not they attended, they get the full picture in three minutes without touching the transcript.",
            "",
            "Quality bar:",
            "- Lead with outcomes, not process. Never write bare narration like \"discussed X\" / \"X에 대해 논의했다\" — always say what was said, by whom, and why it matters.",
            "- Preserve every concrete detail that carries meaning: numbers, amounts, prices, percentages, dates, deadlines, and the names of people, companies, and products. A summary that drops the numbers is useless.",
            "- When speakers disagree or weigh options, record the competing positions and the reason the discussion landed where it did.",
            "- Do not pad. If little of substance happened, keep the report short and honest — never inflate thin content into fake structure.",
            "",
            "Field guide:",
            "- tldr: 2–3 sentences — what this conversation was, the single most important outcome or takeaway, and what happens next.",
            "- sections: 2–6 topics ordered by importance, not chronology. Each heading names the topic concretely (\"미국 D2C 진출 채널\", not \"사업 논의\"). Each bullet is one standalone fact, claim, or argument, with its owner and its specifics.",
            "- decisions: only what was actually agreed or settled — a wish or an idea is not a decision. State each decision together with its stated reason or consequence.",
            "- actionItems: each must be executable weeks later without re-reading anything — start with a verb, name the concrete deliverable, and carry the needed context (a bare \"look into X\" is banned: say what, why, and how far). Resolve relative deadlines (\"다음 주까지\", \"by Friday\") into ISO dates using today's date from the prompt; omit due when none was stated.",
            "- openQuestions: questions raised but left unresolved — the things the attendees must not forget.",
            "",
            "Rules:",
            "- Write every output field in the language the transcript is written in (Korean meetings are the norm — keep them Korean).",
            "- Use speaker names exactly as they appear in the transcript.",
            "- Never invent content, decisions, owners, or deadlines that are not in the transcript.",
            "- Call the \(toolName) tool exactly once with your result.",
        ]
        if style == .enhancedNotes {
            lines.append("- The user provided rough notes: complete and clean them up using the transcript, preserving the user's intent and structure, and return them in enhancedNotesMarkdown.")
        }
        return lines.joined(separator: "\n")
    }

    static func userPrompt(transcript: AttributedTranscript, userNotes: String?, style: NoteStyle,
                           today: Date = Date()) -> String {
        var sections: [String] = []

        let styleHint: String
        switch style {
        case .meetingSummary:
            styleHint = "Produce the structured meeting report."
        case .enhancedNotes:
            styleHint = "Enhance the user's rough notes using the transcript, and also produce the structured meeting report."
        case .actionItems:
            styleHint = "Focus on extracting clear, assignable action items (plus the structured meeting report)."
        }
        sections.append("Task: \(styleHint)")

        // The model needs an anchor date to turn "다음 주 금요일까지" into a real
        // due date — summarization runs right after the meeting, so now ≈ then.
        var context = ["Today's date: \(dateLine(from: today))."]
        let minutes = Int((transcript.turns.map(\.end).max() ?? 0) / 60)
        if minutes >= 1 {
            context.append("Meeting duration: about \(minutes) minutes.")
        }
        sections.append(context.joined(separator: " "))

        if let userNotes, !userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("User's rough notes:\n\(userNotes)")
        }

        sections.append("Transcript:\n\(formatTranscript(transcript))")
        return sections.joined(separator: "\n\n")
    }

    static func dateLine(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd (EEEE)"
        return formatter.string(from: date)
    }

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
                "description": "A short, specific title naming the topic and, when there is one, the outcome — e.g. \"미국 진출 전략: D2C 우선 결정\", not \"주간 회의\".",
            ],
            "tldr": [
                "type": "string",
                "description": "2–3 sentences: what this conversation was, the single most important outcome or takeaway, and what happens next. No markdown headings.",
            ],
            "sections": [
                "type": "array",
                "description": "The discussion broken into 2–6 topics, ordered by importance. Skip small talk.",
                "items": [
                    "type": "object",
                    "properties": [
                        "heading": ["type": "string", "description": "The topic, stated concretely."],
                        "bullets": [
                            "type": "array",
                            "description": "Standalone facts, claims, or arguments — each with its owner and its specifics (numbers, names, reasons).",
                            "items": ["type": "string"],
                        ],
                    ],
                    "required": ["heading", "bullets"],
                ],
            ],
            "decisions": [
                "type": "array",
                "description": "Only what was actually agreed or settled. Each entry states the decision plus its stated reason or consequence, e.g. \"미국 시장 우선 진출 — 국내 OEM 협상이 막혀 있고 마진 구조가 미국이 유리해서\".",
                "items": ["type": "string"],
            ],
            "actionItems": [
                "type": "array",
                "description": "Action items agreed in the meeting. Each must stand alone in a todo list weeks later.",
                "items": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "Verb-first, concrete deliverable, with enough context to act without re-reading the meeting. Never a bare \"알아보기\"/\"look into\"."],
                        "assigneeName": ["type": "string", "description": "The person responsible, if stated. Use the speaker's name from the transcript."],
                        "due": ["type": "string", "description": "Due date as an ISO 8601 date (YYYY-MM-DD). Resolve relative mentions using today's date from the prompt; omit if no deadline was stated."],
                    ],
                    "required": ["text", "assigneeName", "due"],
                ],
            ],
            "openQuestions": [
                "type": "array",
                "description": "Questions raised but left unresolved — what the attendees must not forget. Empty array if none.",
                "items": ["type": "string"],
            ],
        ]

        var required = ["title", "tldr", "sections", "decisions", "actionItems", "openQuestions"]

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
    /// `summaryMarkdown` survives as an optional legacy field so a model that
    /// ignores the section structure still yields a usable summary.
    struct NotesToolInput: Decodable {
        struct ActionItem: Decodable {
            var text: String
            var assigneeName: String?
            var due: String?
        }
        struct Section: Decodable {
            var heading: String
            var bullets: [String]
        }
        /// The time-anchored per-topic form. The current schema asks for
        /// `sections` instead, but notes generated under the topic schema — and
        /// the OpenAI path when the model reverts to it — still decode here.
        struct Topic: Decodable {
            var title: String
            var timeRange: String?
            var keyPoints: [String]?
            var quotes: [String]?
        }
        /// Accepts either a bare string (the current schema) or the object form
        /// carrying rationale and decider, so neither shape is a decode failure.
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
        var tldr: String?
        var sections: [Section]?
        var summaryMarkdown: String?
        var topics: [Topic]?
        var decisions: [Decision]?
        var actionItems: [ActionItem]?
        var openQuestions: [String]?
        var enhancedNotesMarkdown: String?
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
        return try notes(fromWireData: inputData, style: style, userNotes: userNotes)
    }

    /// Shared by the Anthropic and OpenAI paths: both produce the same wire JSON.
    static func notes(fromWireData inputData: Data, style: NoteStyle, userNotes: String?) throws -> MeetingNotes {
        let wire: NotesToolInput
        do {
            wire = try JSONDecoder().decode(NotesToolInput.self, from: inputData)
        } catch {
            throw ClaudeSummarizerError.decoding(error)
        }

        let sections = wire.sections ?? []
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

        // Two report shapes reach this point: the current TL;DR + sections one,
        // and the time-anchored topic one. Render whichever the model actually
        // returned rather than dropping the half it wasn't asked for.
        let summary: String
        if sections.isEmpty, !topics.isEmpty {
            summary = MeetingNotes.composeSummaryMarkdown(
                overview: wire.summaryMarkdown ?? wire.tldr ?? "",
                topics: topics,
                openQuestions: openQuestions)
        } else {
            summary = composeSummaryMarkdown(
                tldr: wire.tldr,
                sections: sections,
                openQuestions: openQuestions,
                legacySummary: wire.summaryMarkdown
            )
        }

        return MeetingNotes(
            title: wire.title,
            summaryMarkdown: summary,
            decisions: decisionDetails.map(\.line),
            actionItems: actionItems,
            enhancedNotesMarkdown: enhanced,
            topics: topics,
            decisionDetails: decisionDetails,
            openQuestions: openQuestions
        )
    }

    /// One report layout for every consumer (detail view, clipboard, Obsidian,
    /// nightly digest): TL;DR paragraph, bold topic headers with bullets, then
    /// open questions. Bold headers rather than `#` headings — SwiftUI's inline
    /// markdown renders bold but shows heading marks literally.
    static func composeSummaryMarkdown(
        tldr: String?,
        sections: [NotesToolInput.Section],
        openQuestions: [String],
        legacySummary: String?
    ) -> String {
        var blocks: [String] = []
        if let tldr = tldr?.trimmingCharacters(in: .whitespacesAndNewlines), !tldr.isEmpty {
            blocks.append(tldr)
        }
        for section in sections where !section.bullets.isEmpty {
            let bullets = section.bullets.map { "- \($0)" }.joined(separator: "\n")
            blocks.append("**\(section.heading)**\n\(bullets)")
        }
        if !openQuestions.isEmpty {
            let heading = containsHangul(blocks.joined() + openQuestions.joined())
                ? "미해결 질문" : "Open questions"
            blocks.append("**\(heading)**\n" + openQuestions.map { "- \($0)" }.joined(separator: "\n"))
        }
        if blocks.isEmpty {
            return legacySummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return blocks.joined(separator: "\n\n")
    }

    /// The report follows the transcript's language, not the app locale, so the
    /// one label we add ourselves has to be inferred from the content.
    static func containsHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
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
