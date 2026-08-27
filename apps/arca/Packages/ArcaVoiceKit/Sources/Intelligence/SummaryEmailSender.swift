import CryptoKit
import Foundation
import ArcaVoiceCore
import Store

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
    private let sendHandler: @Sendable (String, String, String) async throws -> Void

    public init(apiKey: String, userId: String, connectedAccountId: String) {
        self.apiKey = apiKey
        self.userId = userId
        self.connectedAccountId = connectedAccountId
        self.sendHandler = { recipient, subject, htmlBody in
            try await Self.sendViaComposio(
                apiKey: apiKey,
                userId: userId,
                connectedAccountId: connectedAccountId,
                recipient: recipient,
                subject: subject,
                htmlBody: htmlBody
            )
        }
    }

    public init(sendHandler: @escaping @Sendable (String, String, String) async throws -> Void) {
        self.apiKey = ""
        self.userId = ""
        self.connectedAccountId = ""
        self.sendHandler = sendHandler
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
        try await sendHandler(recipient, subject, htmlBody)
    }

    /// A local file to attach. Composio's Gmail tools take files as
    /// `{name, mimetype, s3key}` after a presigned upload — see
    /// `uploadAttachment`.
    public struct Attachment: Sendable {
        public var fileURL: URL
        public var name: String
        public var mimetype: String

        public init(fileURL: URL, name: String? = nil, mimetype: String? = nil) {
            self.fileURL = fileURL
            self.name = name ?? fileURL.lastPathComponent
            self.mimetype = mimetype ?? DocumentVault.mimeType(for: fileURL)
        }
    }

    /// Full-featured send: optional attachment, and when `threadId` is set the
    /// mail goes out as an in-thread reply (GMAIL_REPLY_TO_THREAD) so it lands
    /// under the original conversation instead of starting a new one.
    /// Requires real credentials (not the test sendHandler init).
    ///
    /// GMAIL_REPLY_TO_THREAD argument shape live-verified against
    /// GET /api/v3/tools/GMAIL_REPLY_TO_THREAD: thread_id, recipient_email,
    /// message_body (NOT `body` — that's the send tool's name), is_html,
    /// attachment.
    public func send(to recipient: String, subject: String, htmlBody: String,
                     threadId: String?, attachment: Attachment?) async throws {
        guard !apiKey.isEmpty else {
            // Handler-injected (test) instance has no transport for these —
            // failing loudly beats a test that asserts a send whose attachment
            // silently never existed.
            guard attachment == nil, threadId == nil else {
                throw EmailError.tool("attachment/thread transport unavailable on handler-injected sender")
            }
            try await sendHandler(recipient, subject, htmlBody)
            return
        }
        var uploaded: [String: Any]?
        if let attachment {
            let toolSlug = (threadId?.isEmpty == false) ? "GMAIL_REPLY_TO_THREAD" : "GMAIL_SEND_EMAIL"
            uploaded = try await Self.uploadAttachment(apiKey: apiKey, toolSlug: toolSlug,
                                                       attachment: attachment)
        }
        if let threadId, !threadId.isEmpty {
            var arguments: [String: Any] = [
                "thread_id": threadId,
                "recipient_email": recipient,
                "message_body": htmlBody,
                "is_html": true,
            ]
            if let uploaded { arguments["attachment"] = uploaded }
            try await Self.executeGmailTool(slug: "GMAIL_REPLY_TO_THREAD", apiKey: apiKey,
                                            userId: userId, connectedAccountId: connectedAccountId,
                                            arguments: arguments)
        } else {
            var arguments: [String: Any] = [
                "recipient_email": recipient,
                "subject": subject,
                "body": htmlBody,
                "is_html": true,
            ]
            if let uploaded { arguments["attachment"] = uploaded }
            try await Self.executeGmailTool(slug: "GMAIL_SEND_EMAIL", apiKey: apiKey,
                                            userId: userId, connectedAccountId: connectedAccountId,
                                            arguments: arguments)
        }
    }

    /// Gmail rejects attachments over 25 MB; refuse before reading the file
    /// into memory (the whole payload is buffered for the transport).
    static let maxAttachmentBytes = 20 * 1024 * 1024

    /// Presigned upload for a tool file parameter (live-verified flow, with
    /// lowercase-hex md5): POST /api/v3/files/upload/request → PUT bytes to
    /// `new_presigned_url` → pass `{name, mimetype, s3key: key}` as the tool's
    /// `attachment` argument.
    private static func uploadAttachment(apiKey: String, toolSlug: String,
                                         attachment: Attachment) async throws -> [String: Any] {
        let size = (try? attachment.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxAttachmentBytes else {
            throw EmailError.tool("attachment too large (\(size / 1_048_576) MB > 20 MB): \(attachment.name)")
        }
        let data = try Data(contentsOf: attachment.fileURL)
        let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()

        var request = URLRequest(url: URL(string:
            "https://backend.composio.dev/api/v3/files/upload/request")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "toolkit_slug": "gmail",
            "tool_slug": toolSlug,
            "filename": attachment.name,
            "mimetype": attachment.mimetype,
            "md5": md5,
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (respData, response) = try await uploadBody(URLSession.shared, for: request, body: payload)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = String(data: respData, encoding: .utf8) ?? ""
            throw EmailError.http(status, "upload request: \(String(message.prefix(300)))")
        }
        guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let key = json["key"] as? String,
              let presigned = (json["new_presigned_url"] as? String) ?? (json["newPresignedUrl"] as? String),
              let putURL = URL(string: presigned) else {
            let message = String(data: respData, encoding: .utf8) ?? ""
            throw EmailError.tool("upload request returned an unexpected shape: \(String(message.prefix(300)))")
        }

        var put = URLRequest(url: putURL)
        put.httpMethod = "PUT"
        put.setValue(attachment.mimetype, forHTTPHeaderField: "Content-Type")
        let (_, putResponse) = try await uploadBody(URLSession.shared, for: put, body: data)
        guard let putHTTP = putResponse as? HTTPURLResponse,
              (200..<300).contains(putHTTP.statusCode) else {
            throw EmailError.http((putResponse as? HTTPURLResponse)?.statusCode ?? 0,
                                  "attachment upload PUT failed")
        }
        return ["name": attachment.name, "mimetype": attachment.mimetype, "s3key": key]
    }

    private static func executeGmailTool(slug: String, apiKey: String, userId: String,
                                         connectedAccountId: String,
                                         arguments: [String: Any]) async throws {
        var request = URLRequest(url: URL(string:
            "https://backend.composio.dev/api/v3/tools/execute/\(slug)")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "connected_account_id": connectedAccountId,
            "user_id": userId,
            "arguments": arguments,
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await uploadBody(URLSession.shared, for: request, body: payload)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw EmailError.http((response as? HTTPURLResponse)?.statusCode ?? 0,
                                  String(message.prefix(300)))
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let successful = json["successful"] as? Bool, successful == false {
            let message = ((json["error"] as? [String: Any])?["message"] as? String)
                ?? (json["error"] as? String) ?? "tool error"
            throw EmailError.tool(message)
        }
    }

    private static func sendViaComposio(apiKey: String, userId: String, connectedAccountId: String,
                                        recipient: String, subject: String,
                                        htmlBody: String) async throws {
        try await executeGmailTool(slug: "GMAIL_SEND_EMAIL", apiKey: apiKey, userId: userId,
                                   connectedAccountId: connectedAccountId,
                                   arguments: [
                                       "recipient_email": recipient,
                                       "subject": subject,
                                       "body": htmlBody,
                                       "is_html": true,
                                   ])
    }

    /// Renders MeetingNotes as the summary email and sends it.
    public func sendSummary(to recipient: String, sessionTitle: String,
                            notes: MeetingNotes, date: Date) async throws {
        let subject = "📝 \(notes.title.isEmpty ? sessionTitle : notes.title)"
        try await send(to: recipient, subject: subject,
                       htmlBody: Self.html(sessionTitle: sessionTitle, notes: notes, date: date))
    }

    public func sendSummary(to recipients: [String], sessionTitle: String,
                            notes: MeetingNotes, date: Date) async -> [EmailSendResult] {
        let normalized = Self.normalizedRecipients(recipients)
        var results: [EmailSendResult] = []
        for recipient in normalized {
            do {
                try await sendSummary(to: recipient, sessionTitle: sessionTitle, notes: notes, date: date)
                results.append(EmailSendResult(recipient: recipient, success: true, errorDescription: nil))
            } catch {
                results.append(EmailSendResult(
                    recipient: recipient,
                    success: false,
                    errorDescription: error.localizedDescription
                ))
            }
        }
        return results
    }

    public func sendSummary(record: RecordingSession, notes: MeetingNotes,
                            to recipients: [String]) async -> [EmailSendResult] {
        await sendSummary(to: recipients, sessionTitle: record.title, notes: notes, date: record.createdAt)
    }

    public static func normalizedRecipients(_ recipients: [String]) -> [String] {
        var seen: Set<String> = []
        var output: [String] = []
        for raw in recipients {
            let recipient = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !recipient.isEmpty else { continue }
            let key = recipient.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            output.append(recipient)
        }
        return output
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

public struct EmailSendResult: Sendable, Equatable, Identifiable {
    public var id: String { recipient }
    public var recipient: String
    public var success: Bool
    public var errorDescription: String?

    public init(recipient: String, success: Bool, errorDescription: String? = nil) {
        self.recipient = recipient
        self.success = success
        self.errorDescription = errorDescription
    }
}
