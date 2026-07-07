#if os(macOS)
import Foundation
import ArcaVoiceKit

/// Pulls recent inbound items from ARCA's connected sources (Gmail via Composio).
/// Extend with Slack/calendar the same way. Read-only.
enum ZoneSources {
    struct Inbound: Sendable {
        var title: String
        var body: String
        var source: String
    }

    static func recentInbound(limit: Int = 8) async -> [Inbound] {
        guard let conn = ArcaConfig.loadConnections(),
              let apiKey = conn.composioApiKey, !apiKey.isEmpty,
              let gmail = conn.connectedAccounts?["GMAIL"], !gmail.isEmpty else {
            return []
        }
        return await fetchGmailUnread(apiKey: apiKey, userId: conn.userId,
                                      account: gmail, limit: limit)
    }

    private static func fetchGmailUnread(apiKey: String, userId: String, account: String,
                                         limit: Int) async -> [Inbound] {
        var request = URLRequest(url: URL(string: "https://backend.composio.dev/api/v3/tools/execute/GMAIL_FETCH_EMAILS")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let args: [String: Any] = [
            "connected_account_id": account, "user_id": userId,
            "arguments": ["max_results": limit, "query": "is:unread newer_than:1d"],
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: args),
              let (data, response) = try? await uploadBody(URLSession.shared, for: request, body: payload),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = json["data"] as? [String: Any] else {
            return []
        }
        let messages = (dataDict["messages"] as? [[String: Any]])
            ?? (dataDict["emails"] as? [[String: Any]]) ?? []
        return messages.prefix(limit).map { m in
            let sender = (m["sender"] as? String) ?? "(Unknown sender)"
            let subject = (m["subject"] as? String) ?? "(No subject)"
            let preview = (m["preview"] as? [String: Any])?["body"] as? String
            let body = preview ?? (m["messageText"] as? String) ?? ""
            return Inbound(title: "📧 \(subject) — \(sender)",
                           body: String(body.prefix(600)), source: "gmail")
        }
    }
}
#endif
