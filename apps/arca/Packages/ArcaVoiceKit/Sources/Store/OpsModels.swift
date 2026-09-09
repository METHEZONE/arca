import Foundation
import SwiftData

/// A reply ARCA drafted for an inbound message (Slack or Gmail) — nothing is
/// ever sent without an explicit Approve, unless the user's autonomy level
/// says routine sends are pre-approved. The loop: triage → draft → ARCA asks
/// one question ("최신 사업자등록증을 첨부해서 보낼까요?") → yes / no / your
/// own direction → it flies.
@Model
public final class ReplyProposal {
    public var uid: UUID = UUID()
    /// "slack" | "gmail".
    public var sourceRaw: String = "slack"
    /// Slack channel id, or the recipient email address for gmail.
    public var channel: String = ""
    /// Slack: thread timestamp when replying in-thread; Gmail: the Gmail
    /// thread id so the reply lands in the original thread. Empty = new.
    public var threadTs: String = ""
    public var author: String = ""
    /// The inbound message being answered.
    public var original: String = ""
    /// ARCA's suggested reply (editable before approving).
    public var draft: String = ""
    /// Email subject — set for gmail proposals, nil for Slack.
    public var subject: String?
    /// The one-line question ARCA asks the user, in the user's language
    /// ("엘케이랩코리아에 최신 사업자등록증을 첨부해서 회신할까요?").
    public var question: String?
    /// Local path of the file to attach (resolved from the document vault).
    public var attachmentPath: String?
    /// Display name of the attachment.
    public var attachmentName: String?
    /// Triage judged this a routine, low-stakes fulfillment — eligible for
    /// auto-send at autonomy ≥ sendRoutine.
    public var routine: Bool = false
    /// Sent by ARCA on its own (autonomy gate passed) rather than by a tap.
    public var autoSent: Bool = false
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
