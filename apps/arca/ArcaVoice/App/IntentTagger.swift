import Foundation
import ArcaVoiceKit
#if canImport(PostHog)
import PostHog
#endif

/// What people use ARCA for, without shipping what they said.
///
/// Each chat message, new to-do, and finished meeting gets one cheap model
/// call that returns a category and a ten-word gist with names and numbers
/// stripped; only those two go to PostHog as an `intent` event. The words
/// themselves never leave the ARCA Cloud call they were already part of.
enum IntentTagger {
    static let categories = ["회의 정리", "할 일·일정", "메일·메시지 작성", "조사·검색",
                             "기억 찾기", "생각·아이디어 정리", "상담·고민", "잡담", "기타"]

    static func tag(_ text: String, surface: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let key = ArcaCloud.anthropicKey, !key.isEmpty else { return }
        let url = ArcaCloud.anthropicMessagesURL
        Task.detached(priority: .utility) {
            guard let (intent, gist) = await classify(String(text.prefix(1200)), key: key, url: url) else { return }
            #if canImport(PostHog)
            PostHogSDK.shared.capture("intent", properties: ["surface": surface, "intent": intent, "gist": gist])
            #endif
        }
    }

    private static func classify(_ text: String, key: String, url: URL) async -> (String, String)? {
        let system = """
        Classify what the user wants from their AI assistant. Reply with JSON only: \
        {"intent": one of \(categories), "gist": "<Korean, at most 10 words, what they wanted>"}. \
        The gist must not contain names of people or companies, emails, phone numbers, amounts, or dates.
        """
        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001", "max_tokens": 120, "system": system,
            "messages": [["role": "user", "content": text]],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        guard let payload = try? JSONSerialization.data(withJSONObject: body),
              let (data, response) = try? await URLSession.shared.upload(for: request, from: payload),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let reply = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"),
              let parsed = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: String],
              let intent = parsed["intent"], categories.contains(intent)
        else { return nil }
        return (intent, String((parsed["gist"] ?? "").prefix(60)))
    }
}
