import Foundation
import ArcaVoiceCore
import Vitals

/// What ARCA concluded from a couple of weeks of the user's body and focus data.
public struct VitalsCoachResult: Codable, Equatable, Sendable {
    /// One sentence naming the pattern that matters most right now.
    public var headline: String
    public var sleepAdvice: [String]
    public var focusAdvice: [String]
    /// The single change worth making — the thing to do if nothing else.
    public var oneThing: String
    public var generatedAt: Date

    public init(headline: String, sleepAdvice: [String], focusAdvice: [String],
                oneThing: String, generatedAt: Date = .now) {
        self.headline = headline
        self.sleepAdvice = sleepAdvice
        self.focusAdvice = focusAdvice
        self.oneThing = oneThing
        self.generatedAt = generatedAt
    }
}

/// Reads the user's recent vitals and focus profile and says what to change.
///
/// The prompt binds it hard to the supplied numbers and forbids clinical claims.
/// This is a companion reasoning about sleep and focus habits, not a diagnostic
/// tool, and the difference has to be enforced in the prompt rather than hoped
/// for — a companion that speculates about someone's health is a liability.
public struct VitalsCoach: Sendable {
    private let apiKey: String
    private let model: String
    private let endpoint = ArcaCloud.anthropicMessagesURL

    public init(apiKey: String, model: String = "claude-sonnet-5") {
        self.apiKey = apiKey
        self.model = model
    }

    public func advise(days: [DailyVitals], windows: [FocusWindow],
                       calendar: Calendar = .current) async throws -> VitalsCoachResult {
        let context = VitalsPrompt.coachContext(days: days, windows: windows, calendar: calendar)
        guard !context.isEmpty else { throw CoachError.notEnoughData }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 90

        let tool: [String: Any] = [
            "name": "write_vitals_advice",
            "description": "Give the user concrete, Korean advice on sleep and focus timing.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "headline": [
                        "type": "string",
                        "description": "One Korean sentence naming the single most important pattern in the data",
                    ],
                    "sleepAdvice": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "2-4 concrete Korean actions about sleep, each citing the number that motivates it",
                    ],
                    "focusAdvice": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "2-4 concrete Korean actions about when and how to schedule deep work",
                    ],
                    "oneThing": [
                        "type": "string",
                        "description": "The single highest-leverage change, in Korean, one sentence",
                    ],
                ],
                "required": ["headline", "sleepAdvice", "focusAdvice", "oneThing"],
            ] as [String: Any],
        ]

        let instruction = """
        너는 ARCA — 사용자의 컴패니언이다. 아래는 사용자의 최근 수면·HRV·안정심박·몰입 기록이다.
        이걸 근거로 (1) 수면을 어떻게 개선할지, (2) 몰입을 언제 어떻게 배치할지 조언해라.

        규칙:
        - 반드시 아래 데이터에 있는 숫자만 인용해라. 없는 수치를 만들지 마라.
        - 각 조언은 "무엇을 언제 하라"는 행동으로 써라. "수면을 개선하세요" 같은 말은 금지.
        - 근거가 된 숫자를 조언 안에 같이 적어라. 예: "취침이 01:30까지 밀린 날 3일 모두 깊은 수면이 40분 아래였어요 — 24:30까지 눕는 걸 이번 주 목표로."
        - 데이터가 부족한 항목은 "아직 판단할 데이터가 부족해요"라고 솔직히 말해라. 추측으로 채우지 마라.
        - 진단·질병·치료 얘기는 절대 하지 마라. 너는 의료 도구가 아니다. 수치가 이상하면 병명을 추측하는 대신 "지속되면 전문가와 상의"로 넘겨라.
        - 반말은 쓰지 말고, 사용자를 "민성님" 대신 존댓말로 자연스럽게 대해라.

        \(String(context.prefix(12000)))
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1600,
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": "write_vitals_advice"],
            "messages": [["role": "user", "content": [["type": "text", "text": instruction]]]],
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await uploadBody(URLSession.shared, for: request, body: payload)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? ""
            throw CoachError.api((response as? HTTPURLResponse)?.statusCode ?? 0, message)
        }
        AIUsageLog.recordResponse(provider: "anthropic", model: model, source: "vitals-coach", data: data)
        return try Self.parse(from: data)
    }

    public static func parse(from data: Data, now: Date = .now) throws -> VitalsCoachResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let toolUse = content.first(where: { ($0["type"] as? String) == "tool_use" }),
              let input = toolUse["input"] else {
            throw CoachError.noToolUse
        }
        struct Wire: Decodable {
            var headline: String
            var sleepAdvice: [String]
            var focusAdvice: [String]
            var oneThing: String
        }
        let wire = try JSONDecoder().decode(
            Wire.self, from: try JSONSerialization.data(withJSONObject: input))
        return VitalsCoachResult(headline: wire.headline,
                                 sleepAdvice: wire.sleepAdvice,
                                 focusAdvice: wire.focusAdvice,
                                 oneThing: wire.oneThing,
                                 generatedAt: now)
    }

    public enum CoachError: Error, LocalizedError {
        case api(Int, String)
        case noToolUse
        case notEnoughData

        public var errorDescription: String? {
            switch self {
            case .api(let status, let message):
                return "Vitals coach failed (HTTP \(status)): \(message)"
            case .noToolUse:
                return "Couldn't parse the vitals advice response"
            case .notEnoughData:
                return "조언을 만들 만큼 기록이 쌓이지 않았어요."
            }
        }
    }
}
