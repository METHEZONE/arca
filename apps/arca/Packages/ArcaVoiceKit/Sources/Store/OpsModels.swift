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

/// Something ARCA noticed in an inbound message and wants to do for the
/// user — put a meeting on the calendar, track a deadline — but asks first.
/// Lives until answered; the notification bell shows what's still open.
@Model
public final class ActionProposal {
    public var uid: UUID = UUID()
    /// calendar | task
    public var kindRaw: String = "calendar"
    /// gmail | slack | paste
    public var sourceRaw: String = "gmail"
    public var sender: String = ""
    public var subject: String = ""
    /// One line, in the user's language: what the message was.
    public var summary: String = ""
    /// The yes/no question ARCA asks, in the user's language.
    public var question: String = ""
    /// The structured thing to create, as JSON (calendar: title/start/durationMinutes/location/description; task: title/detail/due).
    public var payloadJSON: String = "{}"
    /// proposed | accepted | declined | failed
    public var stateRaw: String = "proposed"
    public var createdAt: Date = Date.now
    public var resolvedAt: Date?
    public var note: String?

    public init(kind: String, source: String, sender: String, subject: String,
                summary: String, question: String, payloadJSON: String) {
        self.uid = UUID()
        self.kindRaw = kind
        self.sourceRaw = source
        self.sender = sender
        self.subject = subject
        self.summary = summary
        self.question = question
        self.payloadJSON = payloadJSON
        self.stateRaw = "proposed"
        self.createdAt = .now
    }

    public var payload: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(payloadJSON.utf8)) as? [String: Any]) ?? [:]
    }
}
