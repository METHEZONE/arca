import Foundation

/// Intrinsic side-effect class of an agent action — ported from OpenWorker's
/// `risk.py` (MIT). Risk is a DECLARED property of the action, not an LLM
/// judgment: the autonomy gate reads it deterministically, every time.
/// (`AutonomyClassifier` still judges whole *tasks*; this classifies the
/// individual actions a chat turn wants to execute.)
public enum ActionRiskClass: String, Codable, Sendable {
    /// No side effects — always allowed.
    case read
    /// Mutates local state (files, notes, todos) — reversible.
    case writeLocal
    /// Side effects that leave the machine (send email/message, create
    /// calendar events others see) — the approval-inbox hook.
    case external

    /// The autonomy level required to run this without asking.
    public var minimumAutonomy: AutonomyLevel {
        switch self {
        case .read: return .readOnly
        case .writeLocal: return .readOnly
        case .external: return .sendRoutine
        }
    }
}

/// The chat action registry: every `[TAG:]` action the model can emit, with
/// its declared risk and any standing user pre-approval.
public enum ChatAction: String, Sendable {
    case calendar
    case email
    case browser

    public var risk: ActionRiskClass {
        switch self {
        case .calendar: return .external
        case .email: return .external
        case .browser: return .external
        }
    }

    /// Standing user pre-approvals override the gate — the user has said
    /// "just do it" for these (e.g. calendar: "굳이 안물어보고 바로 넣어줘").
    public var userPreapproved: Bool {
        switch self {
        case .calendar: return true
        case .email, .browser: return false
        }
    }

    /// Whether this action may run immediately at the given autonomy level.
    public func allowedWithoutApproval(at level: AutonomyLevel) -> Bool {
        if userPreapproved { return true }
        return level >= risk.minimumAutonomy
    }
}
