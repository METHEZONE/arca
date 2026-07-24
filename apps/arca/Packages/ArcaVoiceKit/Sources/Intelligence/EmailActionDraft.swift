import Foundation

/// An email the chat model asked ARCA to send via an `[EMAIL: {…}]` action
/// tag. Mirrors the JSON shape promised in `ClaudeChat.systemPrompt`.
public struct EmailActionDraft: Codable, Equatable, Sendable {
    public var to: String
    public var subject: String
    /// Plain text; newlines are \n.
    public var body: String

    public init(to: String, subject: String, body: String) {
        self.to = to
        self.subject = subject
        self.body = body
    }

    /// Minimal HTML rendering for the Gmail transport.
    public var htmlBody: String {
        let escaped = body
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<p>" + escaped.replacingOccurrences(of: "\n", with: "<br>") + "</p>"
    }
}
