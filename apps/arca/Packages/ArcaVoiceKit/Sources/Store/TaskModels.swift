import Foundation
import SwiftData

/// How autonomously ARCA may act on the user's behalf. Ascending trust.
/// Stored as the app's global setting AND used to gate whether a task is
/// "tossable" (ARCA can run it in the background without asking).
public enum AutonomyLevel: Int, Codable, Sendable, CaseIterable, Comparable {
    case off = 0            // ARCA never acts on its own
    case readOnly = 1       // gather/summarize/draft only — no outbound actions
    case draftComms = 2     // + prepare messages/emails as drafts (not sent)
    case sendRoutine = 3    // + send routine comms, schedule, file things
    case fullDelegate = 4   // + act end-to-end on most tasks ("arca it")

    public static func < (lhs: AutonomyLevel, rhs: AutonomyLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .off: return "Off (suggestions only)"
        case .readOnly: return "Read & organize only"
        case .draftComms: return "Draft only"
        case .sendRoutine: return "Handle routine tasks & send"
        case .fullDelegate: return "Full delegation (arca it)"
        }
    }

    public var detail: String {
        switch self {
        case .off: return "ARCA won't act on its own — it only makes suggestions."
        case .readOnly: return "Gathers info, summarizes, and researches only. No outbound actions."
        case .draftComms: return "Prepares email/message drafts, but you send them yourself."
        case .sendRoutine: return "Handles routine replies, scheduling, and filing on its own."
        case .fullDelegate: return "Handles most tasks end-to-end on its own."
        }
    }

    /// The current level (kept in sync with UserDefaults by the app).
    /// NOTE: a missing key reads as integer 0, which is a VALID rawValue
    /// (.off) — so an unset value must be detected explicitly or every
    /// engine-side autonomy check silently lands on "never act".
    public static var current: AutonomyLevel {
        guard UserDefaults.standard.object(forKey: "autonomyLevel") != nil else {
            return .readOnly
        }
        return AutonomyLevel(rawValue: UserDefaults.standard.integer(forKey: "autonomyLevel")) ?? .readOnly
    }
}

/// ARCA's own judgment of when a task needs to happen — assigned by the
/// classifier alongside the autonomy call, used to order the quest log.
public enum TaskUrgency: String, Codable, Sendable, CaseIterable {
    case now        // blocking or deadline-critical — do first
    case today      // should happen before the day ends
    case soon       // this week
    case someday    // no real time pressure

    /// Sort order: most urgent first.
    public var rank: Int {
        switch self {
        case .now: return 0
        case .today: return 1
        case .soon: return 2
        case .someday: return 3
        }
    }

    public var label: String {
        switch self {
        case .now: return "NOW"
        case .today: return "TODAY"
        case .soon: return "SOON"
        case .someday: return "SOMEDAY"
        }
    }
}

public enum TaskState: String, Codable, Sendable {
    case open, tossed, running, done, needsUser, failed
    /// Deleted by the user. Kept as a tombstone (not hard-deleted) so relay
    /// merge propagates the deletion instead of resurrecting the task from
    /// the other device; pruned after a week.
    case trashed
}

/// The kind of action a task requires — sets the minimum autonomy level ARCA
/// needs before it may "toss" (auto-run) the task.
public enum TaskActionKind: String, Codable, Sendable {
    case research       // read-only lookup/summary → readOnly
    case draft          // prepare a message/doc → draftComms
    case send           // send/schedule/file → sendRoutine
    case broad          // multi-step, ambiguous → fullDelegate
    case manual         // inherently needs the user (a decision, a meeting)

    public var minimumAutonomy: AutonomyLevel {
        switch self {
        case .research: return .readOnly
        case .draft: return .draftComms
        case .send: return .sendRoutine
        case .broad: return .fullDelegate
        case .manual: return .off // never auto; .off means "never tossable"
        }
    }

    public var isManual: Bool { self == .manual }
}

@Model
public final class TodoTask {
    /// Stable cross-device identity for relay sync.
    public var uid: UUID = UUID()
    public var title: String = ""
    public var detail: String = ""
    public var createdAt: Date = Date.now
    /// Last local mutation — relay merge is last-writer-wins on ties.
    public var updatedAt: Date = Date.now
    public var stateRaw: String = "open"
    public var actionKindRaw: String = "manual"
    public var urgencyRaw: String = "soon"
    /// ARCA's one-line reasoning for the autonomy judgment (why tossable or not).
    public var autonomyRationale: String = ""
    /// Result/log after ARCA runs it.
    public var resultMarkdown: String?
    /// Where it came from: user, zone (a captured notification), iphone, mac…
    public var sourceRaw: String = "user"
    /// When this needs to be done, if known (meeting action items carry one;
    /// user tasks get one when stated). Drives the D-day chip.
    public var dueAt: Date?

    public var state: TaskState {
        get { TaskState(rawValue: stateRaw) ?? .open }
        set { stateRaw = newValue.rawValue }
    }
    public var actionKind: TaskActionKind {
        get { TaskActionKind(rawValue: actionKindRaw) ?? .manual }
        set { actionKindRaw = newValue.rawValue }
    }
    public var urgency: TaskUrgency {
        get { TaskUrgency(rawValue: urgencyRaw) ?? .soon }
        set { urgencyRaw = newValue.rawValue }
    }

    public init(title: String, detail: String = "", actionKind: TaskActionKind = .manual,
                autonomyRationale: String = "", source: String = "user", createdAt: Date = .now) {
        self.uid = UUID()
        self.title = title
        self.detail = detail
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.stateRaw = TaskState.open.rawValue
        self.actionKindRaw = actionKind.rawValue
        self.autonomyRationale = autonomyRationale
        self.resultMarkdown = nil
        self.sourceRaw = source
    }

    /// Whether ARCA may auto-run this at the current (or given) autonomy level.
    public func isTossable(at level: AutonomyLevel = .current) -> Bool {
        guard !actionKind.isManual, level != .off else { return false }
        return level >= actionKind.minimumAutonomy
    }

    /// Mark the record as locally mutated (call after any user/agent change).
    public func touch() { updatedAt = .now }

    /// How far along the task's lifecycle a state is — merge keeps the winner.
    public static func rank(of state: TaskState) -> Int {
        switch state {
        case .open: return 0
        case .tossed: return 1
        case .running: return 2
        case .needsUser, .failed: return 3
        case .done: return 4
        case .trashed: return 5   // a deletion beats everything
        }
    }
}

/// Wire format for the relay (JSON in the arca-brain repo).
public struct TaskWire: Codable, Sendable {
    public var uid: UUID
    public var title: String
    public var detail: String
    public var createdAt: Date
    public var updatedAt: Date
    public var stateRaw: String
    public var actionKindRaw: String
    /// Optional so relay payloads written before urgency existed still decode.
    public var urgencyRaw: String?
    public var autonomyRationale: String
    public var resultMarkdown: String?
    public var sourceRaw: String

    public init(_ task: TodoTask) {
        uid = task.uid
        title = task.title
        detail = task.detail
        createdAt = task.createdAt
        updatedAt = task.updatedAt
        stateRaw = task.stateRaw
        actionKindRaw = task.actionKindRaw
        urgencyRaw = task.urgencyRaw
        autonomyRationale = task.autonomyRationale
        resultMarkdown = task.resultMarkdown
        sourceRaw = task.sourceRaw
    }

    /// Copies the wire's fields onto a local record (identity excluded).
    public func apply(to task: TodoTask) {
        task.title = title
        task.detail = detail
        task.createdAt = createdAt
        task.updatedAt = updatedAt
        task.stateRaw = stateRaw
        task.actionKindRaw = actionKindRaw
        if let urgencyRaw { task.urgencyRaw = urgencyRaw }
        task.autonomyRationale = autonomyRationale
        task.resultMarkdown = resultMarkdown
        task.sourceRaw = sourceRaw
    }
}

/// A persisted line in the running conversation with ARCA (for the hover log).
@Model
public final class ChatLogEntry {
    public var roleRaw: String
    public var text: String
    public var createdAt: Date
    /// Conversation this turn belongs to. Older rows migrate into "legacy".
    public var conversationId: String = "legacy"
    /// Optional project grouping for the companion home chat rail.
    public var projectName: String?
    /// Optional attached image (a screenshot the turn was about), JPEG.
    public var imageData: Data?

    public init(role: String, text: String, conversationId: String = UUID().uuidString,
                projectName: String? = nil, imageData: Data? = nil, createdAt: Date = .now) {
        self.roleRaw = role
        self.text = text
        self.conversationId = conversationId
        self.projectName = projectName
        self.imageData = imageData
        self.createdAt = createdAt
    }
}
