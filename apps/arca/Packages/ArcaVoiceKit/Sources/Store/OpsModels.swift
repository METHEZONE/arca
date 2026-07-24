import Foundation
import SwiftData

/// A reply ARCA drafted for an inbound message (Slack for now) — nothing is
/// ever sent without an explicit Approve. The vida-style loop: triage →
/// draft → you tap → it flies.
@Model
public final class ReplyProposal {
    public var uid: UUID = UUID()
    /// "slack" (later: "gmail").
    public var sourceRaw: String = "slack"
    /// Channel id or name the message came from (send target).
    public var channel: String = ""
    /// Thread timestamp when replying in-thread; empty = top-level.
    public var threadTs: String = ""
    public var author: String = ""
    /// The inbound message being answered.
    public var original: String = ""
    /// ARCA's suggested reply (editable before approving).
    public var draft: String = ""
    /// Email subject — set for gmail proposals, nil for Slack.
    public var subject: String?
    /// proposed | sent | skipped | failed
    public var stateRaw: String = "proposed"
    public var createdAt: Date = Date.now
    public var sentAt: Date?

    public init(source: String, channel: String, threadTs: String = "",
                author: String, original: String, draft: String) {
        self.uid = UUID()
        self.sourceRaw = source
        self.channel = channel
        self.threadTs = threadTs
        self.author = author
        self.original = original
        self.draft = draft
        self.stateRaw = "proposed"
        self.createdAt = .now
    }
}
