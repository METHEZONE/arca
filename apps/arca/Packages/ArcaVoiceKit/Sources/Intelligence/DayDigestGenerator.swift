import Foundation
import ArcaVoiceCore

public struct DayDigest: Equatable, Sendable {
    public var titleSuffix: String
    public var summaryMarkdown: String
    public var unfinished: [String]
    public var progress: [String]

    public init(titleSuffix: String,
                summaryMarkdown: String,
                unfinished: [String],
                progress: [String]) {
        self.titleSuffix = titleSuffix
        self.summaryMarkdown = summaryMarkdown
        self.unfinished = unfinished
        self.progress = progress
    }

    public var fullMarkdown: String {
        var sections = [summaryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)]
        if !progress.isEmpty {
            sections.append("## 진행 메모\n" + progress.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !unfinished.isEmpty {
            sections.append("## 미완료/확인 필요\n" + unfinished.map { "- \($0)" }.joined(separator: "\n"))
        }
        return sections.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

public struct DayDigestGenerator: Sendable {
    private let apiKey: String
    private let model: String
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public init(apiKey: String, model: String = "claude-sonnet-5") {
        self.apiKey = apiKey
        self.model = model
    }

    public func generate(timelineMarkdown: String,
                         snapshotJPEGs: [Data]) async throws -> DayDigest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 90

        let tool: [String: Any] = [
            "name": "write_day_digest",
            "description": "Write a factual Korean digest of the user's day.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "titleSuffix": [
                        "type": "string",
                        "description": "A short Korean title suffix, 2-8 words",
                    ],
                    "summaryMarkdown": [
                        "type": "string",
                        "description": "Korean markdown with the requested three sections",
                    ],
                    "unfinished": [
                        "type": "array",
                        "items": ["type": "string"],
                    ],
                    "progress": [
                        "type": "array",
                        "items": ["type": "string"],
                    ],
                ],
                "required": ["titleSuffix", "summaryMarkdown", "unfinished", "progress"],
            ] as [String: Any],
        ]

        var content: [[String: Any]] = [[
            "type": "text",
            "text": """
            너는 ARCA. 아래 타임라인과 화면 스냅샷으로 사용자의 오늘 하루를 정리해라. 섹션: ## 오늘 한 일 (간결한 불릿, 구체적으로), ## 어디까지 했는지 (진행 중이던 작업의 마지막 상태), ## 놓쳤을 수 있는 것 (화면에서 보인 미완료/미답변/에러 등). 사실만, 추측은 '~로 보임'으로 표시.

            \(String(timelineMarkdown.prefix(12000)))
            """,
        ]]

        for jpeg in snapshotJPEGs.prefix(10) {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": jpeg.base64EncodedString(),
                ],
            ])
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2400,
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": "write_day_digest"],
            "messages": [[
                "role": "user",
                "content": content,
            ]],
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await uploadBody(URLSession.shared, for: request, body: payload)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? ""
            throw DigestError.api((response as? HTTPURLResponse)?.statusCode ?? 0, message)
        }
        AIUsageLog.recordResponse(provider: "anthropic", model: model, source: "day-digest", data: data)
        return try Self.parseDigest(from: data)
    }

    public static func parseDigest(from data: Data) throws -> DayDigest {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let toolUse = content.first(where: { ($0["type"] as? String) == "tool_use" }),
              let input = toolUse["input"] else {
            throw DigestError.noToolUse
        }
        let inputData = try JSONSerialization.data(withJSONObject: input)
        struct Wire: Decodable {
            var titleSuffix: String
            var summaryMarkdown: String
            var unfinished: [String]
            var progress: [String]
        }
        let wire = try JSONDecoder().decode(Wire.self, from: inputData)
        return DayDigest(titleSuffix: wire.titleSuffix,
                         summaryMarkdown: wire.summaryMarkdown,
                         unfinished: wire.unfinished,
                         progress: wire.progress)
    }

    public enum DigestError: Error, LocalizedError {
        case api(Int, String)
        case noToolUse

        public var errorDescription: String? {
            switch self {
            case .api(let status, let message):
                return "Day digest failed (HTTP \(status)): \(message)"
            case .noToolUse:
                return "Couldn't parse the day digest response"
            }
        }
    }
}
