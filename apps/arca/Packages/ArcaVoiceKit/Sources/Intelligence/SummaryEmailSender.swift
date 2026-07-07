import Foundation
import ArcaVoiceCore

/// Sends meeting-summary emails through Composio's Gmail toolkit, reusing the
/// credentials in ~/.arca/connections.json (shared with the main ARCA app).
///
/// API shape live-verified by the main app: POST
/// backend.composio.dev/api/v3/tools/execute/GMAIL_SEND_EMAIL with x-api-key,
/// body { connected_account_id, user_id, arguments: { recipient_email, subject,
/// body, is_html } }. `user_id` is required alongside connected_account_id.
public struct ComposioEmailSender: Sendable {
    private let apiKey: String
    private let userId: String
    private let connectedAccountId: String
    private let endpoint = URL(string: "https://backend.composio.dev/api/v3/tools/execute/GMAIL_SEND_EMAIL")!

    public init(apiKey: String, userId: String, connectedAccountId: String) {
        self.apiKey = apiKey
        self.userId = userId
        self.connectedAccountId = connectedAccountId
    }

    /// Builds a sender from ~/.arca/connections.json; nil when Composio or the
    /// Gmail connection isn't configured.
    public static func fromArcaConfig() -> ComposioEmailSender? {
        guard let connections = ArcaConfig.loadConnections(),
              let apiKey = connections.composioApiKey, !apiKey.isEmpty,
              let gmailAccount = connections.connectedAccounts?["GMAIL"], !gmailAccount.isEmpty else {
            return nil
        }
        return ComposioEmailSender(apiKey: apiKey, userId: connections.userId,
                                   connectedAccountId: gmailAccount)
    }

    public func send(to recipient: String, subject: String, htmlBody: String) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "connected_account_id": connectedAccountId,
            "user_id": userId,
            "arguments": [
                "recipient_email": recipient,
                "subject": subject,
                "body": htmlBody,
                "is_html": true,
            ] as [String: Any],
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)

        // upload(from:) — HTML summary bodies can be large; data(for:) with a big
        // httpBody can hang over HTTP/2.
        let (data, response) = try await uploadBody(URLSession.shared, for: request, body: payload)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw EmailError.http((response as? HTTPURLResponse)?.statusCode ?? 0, String(message.prefix(300)))
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let successful = json["successful"] as? Bool, successful == false {
            let message = ((json["error"] as? [String: Any])?["message"] as? String)
                ?? (json["error"] as? String) ?? "tool error"
            throw EmailError.tool(message)
        }
    }

    /// Renders MeetingNotes as the summary email and sends it.
    public func sendSummary(to recipient: String, sessionTitle: String,
                            notes: MeetingNotes, date: Date) async throws {
        let subject = "📝 \(notes.title.isEmpty ? sessionTitle : notes.title)"
        try await send(to: recipient, subject: subject,
                       htmlBody: Self.html(sessionTitle: sessionTitle, notes: notes, date: date))
    }

    static func html(sessionTitle: String, notes: MeetingNotes, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMM d, yyyy (E) HH:mm"

        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        func paragraphs(_ markdown: String) -> String {
            markdown.split(separator: "\n", omittingEmptySubsequences: true)
                .map { "<p style=\"margin:4px 0\">\(escape(String($0)))</p>" }
                .joined()
        }

        var html = """
        <div style="font-family:-apple-system,sans-serif;max-width:640px">
        <h2 style="margin-bottom:2px">\(escape(notes.title.isEmpty ? sessionTitle : notes.title))</h2>
        <p style="color:#777;margin-top:0">\(formatter.string(from: date)) · ARCA</p>
        <h3>Summary</h3>\(paragraphs(notes.summaryMarkdown))
        """
        if let enhanced = notes.enhancedNotesMarkdown, !enhanced.isEmpty {
            html += "<h3>My Notes (finalized)</h3>\(paragraphs(enhanced))"
        }
        if !notes.decisions.isEmpty {
            html += "<h3>Decisions</h3><ul>"
                + notes.decisions.map { "<li>\(escape($0))</li>" }.joined()
                + "</ul>"
        }
        if !notes.actionItems.isEmpty {
            html += "<h3>Action Plan</h3><ul>"
            for item in notes.actionItems {
                var line = escape(item.text)
                if let assignee = item.assigneeName { line += " — <b>\(escape(assignee))</b>" }
                html += "<li>\(line)</li>"
            }
            html += "</ul>"
        }
        html += "<p style=\"color:#aaa;font-size:12px\">This email was sent automatically by ARCA.</p></div>"
        return html
    }

    public enum EmailError: Error, LocalizedError {
        case http(Int, String)
        case tool(String)

        public var errorDescription: String? {
            switch self {
            case .http(let status, let body): return "Email send failed (HTTP \(status)): \(body)"
            case .tool(let message): return "Email send failed: \(message)"
            }
        }
    }
}
