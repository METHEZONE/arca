import Foundation
import ArcaVoiceCore

/// What ARCA noticed across a whole day, rather than inside one meeting.
public struct DailyInsight: Codable, Equatable, Sendable {
    /// One sentence naming what the day was actually about.
    public var headline: String
    /// Things worth remembering that no single meeting note would contain —
    /// threads running across conversations, contradictions, repeated concerns.
    public var insights: [String]
    /// Open loops: what was raised and never resolved.
    public var openLoops: [String]
    /// What to carry into tomorrow.
    public var tomorrow: [String]

    public init(headline: String, insights: [String], openLoops: [String], tomorrow: [String]) {
        self.headline = headline
        self.insights = insights
        self.openLoops = openLoops
        self.tomorrow = tomorrow
    }

    public var isEmpty: Bool {
        insights.isEmpty && openLoops.isEmpty && tomorrow.isEmpty
    }
}

/// Reads the day's meeting notes together and writes the part a per-meeting
/// summary structurally cannot: the connections between them.
///
/// The prompt is deliberately hostile to filler. A daily note that says "you had
/// three meetings and made progress" is worse than no daily note — it trains the
/// user to stop reading. So the model is told to cite which conversation each
/// observation came from, and to return nothing rather than pad.
public struct DailyInsightGenerator: Sendable {
    private let apiKey: String
    private let model: String
    private let endpoint = ArcaCloud.anthropicMessagesURL

    public init(apiKey: String, model: String = "claude-sonnet-5") {
        self.apiKey = apiKey
        self.model = model
    }

    /// `dayMarkdown` is the assembled day (meeting sections, decisions, actions).
    public func generate(dayMarkdown: String, dayLabel: String,
                         focusLine: String? = nil) async throws -> DailyInsight {
        let trimmed = dayMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw InsightError.nothingToRead }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 120

        let tool: [String: Any] = [
            "name": "write_daily_insight",
            "description": "Record what connects the day's conversations.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "headline": [
                        "type": "string",
                        "description": "One sentence naming what this day was actually about",
                    ],
                    "insights": [
                        "type": "array", "items": ["type": "string"],
                        "description": "0-5 observations that span more than one conversation, each citing which ones",
                    ],
                    "openLoops": [
                        "type": "array", "items": ["type": "string"],
                        "description": "0-5 things raised and left unresolved, with where they were raised",
                    ],
                    "tomorrow": [
                        "type": "array", "items": ["type": "string"],
                        "description": "0-4 concrete things to carry into tomorrow",
                    ],
                ],
                "required": ["headline", "insights", "openLoops", "tomorrow"],
            ] as [String: Any],
        ]

        let language = ArcaLanguageResolver.isKorean ? "한국어" : "English"
        var instruction = """
        You are ARCA, reading back over your user's whole day. Below are the \
        meeting and voice notes captured on \(dayLabel), already summarised \
        individually. Your job is the part a single note cannot do: what connects \
        them.

        Write everything in \(language).

        Rules:
        - Only write observations that span MORE THAN ONE conversation, or that \
        contradict something said elsewhere in the day. Anything true of a single \
        meeting already lives in that meeting's note — repeating it is noise.
        - Cite where each observation comes from, by meeting title.
        - Never pad. If the day genuinely has no cross-cutting insight, return an \
        empty `insights` array. An empty section is honest; a filler bullet like \
        "several topics were discussed" teaches the user to stop reading these.
        - `openLoops` means something was raised and left unresolved — not simply \
        an action item that already exists as a task.
        - Do not invent names, numbers, commitments or dates that are not below.
        - No preamble, no encouragement, no summary of the summary.
        """
        if let focusLine {
            instruction += "\n\nFor context on the user's state that day: \(focusLine)"
        }
        instruction += "\n\n---\n\n\(String(trimmed.prefix(24000)))"

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2000,
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": "write_daily_insight"],
            "messages": [["role": "user", "content": [["type": "text", "text": instruction]]]],
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await uploadBody(URLSession.shared, for: request, body: payload)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? ""
            throw InsightError.api((response as? HTTPURLResponse)?.statusCode ?? 0, message)
        }
        AIUsageLog.recordResponse(provider: "anthropic", model: model,
                                  source: "daily-insight", data: data)
        return try Self.parse(from: data)
    }

    public static func parse(from data: Data) throws -> DailyInsight {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let toolUse = content.first(where: { ($0["type"] as? String) == "tool_use" }),
              let input = toolUse["input"] else {
            throw InsightError.noToolUse
        }
        return try JSONDecoder().decode(
            DailyInsight.self, from: try JSONSerialization.data(withJSONObject: input))
    }

    /// The insight section as it appears in the daily note.
    public static func markdown(_ insight: DailyInsight) -> String {
        var lines: [String] = ["## \(L("ARCA가 본 오늘", "What ARCA noticed"))", ""]
        let headline = insight.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        if !headline.isEmpty {
            lines.append("**\(headline)**")
            lines.append("")
        }
        if !insight.insights.isEmpty {
            lines.append(contentsOf: insight.insights.map { "- \($0)" })
            lines.append("")
        }
        if !insight.openLoops.isEmpty {
            lines.append("### \(L("아직 안 닫힌 것", "Still open"))")
            lines.append(contentsOf: insight.openLoops.map { "- \($0)" })
            lines.append("")
        }
        if !insight.tomorrow.isEmpty {
            lines.append("### \(L("내일로", "Into tomorrow"))")
            lines.append(contentsOf: insight.tomorrow.map { "- [ ] \($0)" })
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public enum InsightError: Error, LocalizedError {
        case api(Int, String)
        case noToolUse
        case nothingToRead

        public var errorDescription: String? {
            switch self {
            case .api(let status, let message):
                return "Daily insight failed (HTTP \(status)): \(message)"
            case .noToolUse:
                return "Couldn't parse the daily insight response"
            case .nothingToRead:
                return L("정리할 기록이 없어요.", "Nothing recorded to read back.")
            }
        }
    }
}
