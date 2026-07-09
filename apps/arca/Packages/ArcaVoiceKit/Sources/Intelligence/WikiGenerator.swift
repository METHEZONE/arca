import Foundation
import ArcaVoiceCore

public struct WikiGenerator: Sendable {
    public struct MemoryInput: Sendable {
        public var text: String
        public var kind: String
        public var date: Date

        public init(text: String, kind: String, date: Date) {
            self.text = text
            self.kind = kind
            self.date = date
        }
    }

    public struct SessionInput: Sendable {
        public var title: String
        public var date: Date

        public init(title: String, date: Date) {
            self.title = title
            self.date = date
        }
    }

    private let apiKey: String
    private let model: String
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public init(apiKey: String, model: String = "claude-sonnet-5") {
        self.apiKey = apiKey
        self.model = model
    }

    public func generate(ownerName: String,
                         memories: [MemoryInput],
                         sessions: [SessionInput]) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 90

        let tool: [String: Any] = [
            "name": "write_user_wiki",
            "description": "Write the user's warm, data-grounded biography wiki in Korean markdown.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "markdown": [
                        "type": "string",
                        "description": "Warm Korean markdown with the requested sections. Do not invent unsupported facts.",
                    ],
                ],
                "required": ["markdown"],
            ] as [String: Any],
        ]

        let facts = memories.prefix(200).map {
            "- [\($0.kind)] \(Self.format($0.date)): \($0.text)"
        }.joined(separator: "\n")
        let sessionLines = sessions.prefix(80).map {
            "- \(Self.format($0.date)): \($0.title)"
        }.joined(separator: "\n")

        let userText = """
        너는 ARCA다. 아래 데이터만 근거로 \(ownerName)의 따뜻한 한국어 biography-wiki를 마크다운으로 작성해라.
        추측하거나 꾸며내지 말고, 데이터가 부족한 섹션은 "아직 충분히 알지 못한다"는 식으로 정직하게 써라.

        반드시 포함할 섹션:
        ## 프로필
        ## 하는 일
        ## 진행 중인 프로젝트
        ## 사람들과의 관계
        ## 성향과 취향
        ## 최근 타임라인

        기억:
        \(facts.isEmpty ? "(없음)" : facts)

        세션:
        \(sessionLines.isEmpty ? "(없음)" : sessionLines)
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2400,
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": "write_user_wiki"],
            "messages": [["role": "user", "content": [["type": "text", "text": userText]]]],
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await uploadBody(URLSession.shared, for: request, body: payload)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8).map { String($0.prefix(240)) } ?? ""
            throw WikiError.api((response as? HTTPURLResponse)?.statusCode ?? 0, message)
        }
        AIUsageLog.recordResponse(provider: "anthropic", model: model, source: "wiki", data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let toolUse = content.first(where: { ($0["type"] as? String) == "tool_use" }),
              let input = toolUse["input"] as? [String: Any],
              let markdown = input["markdown"] as? String,
              !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WikiError.noToolUse
        }
        return markdown
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    public enum WikiError: Error, LocalizedError {
        case api(Int, String)
        case noToolUse

        public var errorDescription: String? {
            switch self {
            case .api(let status, let message): return "Wiki generation failed (HTTP \(status)): \(message)"
            case .noToolUse: return "ARCA가 위키 응답을 구조화하지 못했어요."
            }
        }
    }
}
