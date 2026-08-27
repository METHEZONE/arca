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
