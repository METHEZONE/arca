import Foundation
import ArcaVoiceCore

/// What one meeting says about one Notion row.
public struct NotionRowExtraction: Sendable, Equatable {
    /// The existing row this meeting is about, matched verbatim against the
    /// titles handed to the model, or nil when the meeting is about a company
    /// that has no row yet.
    public let matchedRowTitle: String?
    /// The name to use when creating a row (`matchedRowTitle == nil`).
    public let newRowTitle: String?
    /// Column name → plain-string value, still uncoerced. Only columns the
    /// transcript actually spoke to appear here.
    public let properties: [String: String]
    /// Columns the transcript explicitly *changed* — the only ones allowed to
    /// overwrite a value the user already typed.
    public let correctedProperties: Set<String>
    /// Durable facts worth keeping on the page body: MOQ, 설비 유무, 가능한 병 사이즈…
    public let facts: [String]
    public let nextActions: [String]
    /// One line describing where this deal now stands.
    public let statusLine: String

    public init(matchedRowTitle: String?, newRowTitle: String?, properties: [String: String],
                correctedProperties: Set<String> = [], facts: [String] = [],
                nextActions: [String] = [], statusLine: String = "") {
        self.matchedRowTitle = matchedRowTitle
        self.newRowTitle = newRowTitle
        self.properties = properties
        self.correctedProperties = correctedProperties
        self.facts = facts
        self.nextActions = nextActions
        self.statusLine = statusLine
    }
}

/// Reads a meeting transcript against a live Notion database schema and returns
/// the column values the meeting actually established.
///
/// The tool schema is generated from the database, not hardcoded: each column
/// becomes one string field carrying its kind hint and — for select/status —
/// the verbatim list of allowed options. That is what makes this work on the
/// 콜드브루 OEM tracker (업체명 / 담당자명 / Phone / Status) and on whatever
/// database the user builds next without a code change.
///
/// Everything is returned as a string; coercion into Notion's per-kind payloads
/// happens in `NotionPropertyEncoder`, so a value the model formats oddly is
/// dropped in one tested place rather than corrupting a PATCH.
public struct NotionFieldExtractor: Sendable {
    private static let toolName = "fill_notion_row"
    /// Above this many rows the prompt carries titles only — enough to match a
    /// row, without paying for every value in a large database.
    static let valuesIncludedRowLimit = 40

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

    public func extract(
        schema: NotionDatabaseSchema,
        rows: [NotionDBClient.Row],
        transcript: AttributedTranscript,
        notes: MeetingNotes?,
        meetingDate: Date
    ) async throws -> NotionRowExtraction {
        let body = Self.requestBody(model: model, maxTokens: maxTokens, schema: schema,
                                    rows: rows, transcript: transcript, notes: notes,
                                    meetingDate: meetingDate)
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
            throw ClaudeSummarizerError.api(status: http.statusCode,
                                            message: ClaudeSummarizer.apiErrorMessage(from: data))
        }

        AIUsageLog.recordResponse(provider: "anthropic", model: model,
                                  source: "notion-fields", data: data)
        return try Self.parse(from: data, schema: schema, rows: rows)
    }

    // MARK: - Request building

    static func requestBody(
        model: String,
        maxTokens: Int,
        schema: NotionDatabaseSchema,
        rows: [NotionDBClient.Row],
        transcript: AttributedTranscript,
        notes: MeetingNotes?,
        meetingDate: Date
    ) -> [String: Any] {
        [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemPrompt(),
            "messages": [
                [
                    "role": "user",
                    "content": userPrompt(schema: schema, rows: rows, transcript: transcript,
                                          notes: notes, meetingDate: meetingDate),
                ]
            ],
            "tools": [toolDefinition(schema: schema)],
            "tool_choice": ["type": "tool", "name": toolName],
        ]
    }

    static func systemPrompt() -> String {
        [
            "You are ARCA, keeping a Notion database current from meeting and call transcripts.",
            "You will be given a database schema, its existing rows, and one transcript.",
            "Decide which existing row the transcript is about, then extract only the column values the transcript actually establishes.",
            "Omit a column entirely when the transcript does not state its value. Never guess, never infer from context, never carry a value over from another row.",
            "For select and status columns you may only answer with one of the allowed options, copied verbatim. If none of them fits what was said, omit the column.",
            "List a column in corrected_properties only when the transcript explicitly changes a value the row already holds — a new phone number for the same person, a status that has actually moved. A value that merely repeats what is already there is not a correction.",
            "facts are durable specifications worth keeping: minimum order quantities, equipment the vendor has, sizes they can and cannot do, pricing terms. Keep each one short and concrete, and keep the numbers exactly as stated.",
            "next_actions are what the user must do next, not what was already done.",
            "Write every string in the language of the transcript (Korean calls stay Korean). Keep company, person, and product names exactly as spoken.",
            "Call the \(toolName) tool exactly once.",
        ].joined(separator: "\n")
    }

    static func userPrompt(
        schema: NotionDatabaseSchema,
        rows: [NotionDBClient.Row],
        transcript: AttributedTranscript,
        notes: MeetingNotes?,
        meetingDate: Date
    ) -> String {
        var sections: [String] = []

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy-MM-dd (E) HH:mm"
        sections.append("## 이 대화의 시각\n\(formatter.string(from: meetingDate))\n(상대적인 날짜 표현 — \"이번주\", \"다음달\" — 은 이 시각을 기준으로 해석해서 YYYY-MM-DD 로 적어라.)")

        sections.append("## 데이터베이스\n\(schema.title.isEmpty ? "(제목 없음)" : schema.title)")

        var columnLines: [String] = []
        for property in schema.properties {
            var line = "- \(property.name) — \(property.kind.rawValue), \(property.kind.valueHint)"
            if !property.options.isEmpty {
                line += "\n  허용값: \(property.options.joined(separator: " | "))"
            }
            columnLines.append(line)
        }
        sections.append("## 채울 수 있는 컬럼\n\(columnLines.joined(separator: "\n"))")

        if rows.isEmpty {
            sections.append("## 기존 행\n(없음 — 새 행을 만들어야 한다.)")
        } else if rows.count <= valuesIncludedRowLimit {
            let lines = rows.map { row -> String in
                let filled = row.values
                    .filter { $0.key != schema.titleProperty?.name }
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: ", ")
                return filled.isEmpty ? "- \(row.title) (빈 행)" : "- \(row.title) → \(filled)"
            }
            sections.append("## 기존 행과 현재 값\n\(lines.joined(separator: "\n"))")
        } else {
            sections.append("## 기존 행 이름\n\(rows.map { "- \($0.title)" }.joined(separator: "\n"))")
        }

        if let notes, !notes.summaryMarkdown.isEmpty {
            sections.append("## 이미 만들어진 요약\n\(notes.summaryMarkdown)")
        }
        if let notes, !notes.actionItems.isEmpty {
            let items = notes.actionItems.map { item in
                item.assigneeName.map { "- \(item.text) (\($0))" } ?? "- \(item.text)"
            }
            sections.append("## 이미 뽑힌 액션 아이템\n\(items.joined(separator: "\n"))")
        }

        sections.append("## 전사\n\(ClaudeSummarizer.formatTranscript(transcript))")
        return sections.joined(separator: "\n\n")
    }

    static func toolDefinition(schema: NotionDatabaseSchema) -> [String: Any] {
        var columnSchemas: [String: Any] = [:]
        for property in schema.properties {
            var description = property.kind.valueHint
            if !property.options.isEmpty {
                description += ". Allowed values: \(property.options.joined(separator: " | "))"
            }
            columnSchemas[property.name] = ["type": "string", "description": description]
        }

        return [
            "name": toolName,
            "description": "Record what this transcript establishes about one row of the Notion database.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "row": [
                        "type": "string",
                        "description": "The existing row name this transcript is about, copied verbatim from the row list. Use an empty string when none of them is the subject.",
                    ],
                    "new_row_title": [
                        "type": "string",
                        "description": "Only when `row` is empty: the name a new row should get. Leave empty if the transcript is not about a database subject at all.",
                    ],
                    "properties": [
                        "type": "object",
                        "description": "Column name → value, including only columns the transcript actually establishes.",
                        "properties": columnSchemas,
                        "additionalProperties": false,
                    ],
                    "corrected_properties": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Column names whose existing value this transcript explicitly changes.",
                    ],
                    "facts": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Durable specifications established in this conversation.",
                    ],
                    "next_actions": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "What the user must do next.",
                    ],
                    "status_line": [
                        "type": "string",
                        "description": "One line on where this now stands.",
                    ],
                ],
                "required": ["row"],
            ],
        ]
    }

    // MARK: - Parsing

    static func parse(from data: Data, schema: NotionDatabaseSchema,
                      rows: [NotionDBClient.Row]) throws -> NotionRowExtraction {
        guard let input = try ClaudeSummarizer.toolUseInput(from: data) else {
            throw ClaudeSummarizerError.missingToolUse
        }

        let rawRow = (input["row"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // The model is told to copy a title verbatim, but a stray honorific or
        // different spacing must not silently create a duplicate row — fold
        // whitespace and case before giving up on the match.
        let matched = rows.first { $0.title == rawRow }?.title
            ?? rows.first { Self.fold($0.title) == Self.fold(rawRow) }?.title
        let newTitle = (input["new_row_title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var properties: [String: String] = [:]
        if let raw = input["properties"] as? [String: Any] {
            for (name, value) in raw {
                // A column the model invented cannot be written, and a blank is
                // the same as omitting it.
                guard schema.property(named: name) != nil,
                      let text = Self.string(from: value),
                      !text.isEmpty else { continue }
                properties[name] = text
            }
        }

        let corrected = Set((input["corrected_properties"] as? [Any] ?? [])
            .compactMap(Self.string(from:))
            .filter { properties[$0] != nil })

        return NotionRowExtraction(
            matchedRowTitle: matched,
            newRowTitle: (matched == nil && !(newTitle ?? "").isEmpty) ? newTitle : nil,
            properties: properties,
            correctedProperties: corrected,
            facts: (input["facts"] as? [Any] ?? []).compactMap(Self.string(from:)).filter { !$0.isEmpty },
            nextActions: (input["next_actions"] as? [Any] ?? []).compactMap(Self.string(from:)).filter { !$0.isEmpty },
            statusLine: Self.string(from: input["status_line"]) ?? ""
        )
    }

    /// Tool inputs are typed by the model, so a number column can come back as a
    /// JSON number even though the schema said string.
    static func string(from value: Any?) -> String? {
        switch value {
        case let text as String:
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    static func fold(_ value: String) -> String {
        value.lowercased().filter { !$0.isWhitespace }
    }
}
