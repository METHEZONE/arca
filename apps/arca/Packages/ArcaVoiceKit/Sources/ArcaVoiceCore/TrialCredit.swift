import Foundation

/// The free chat balance a new account starts with.
///
/// **Recording and transcription are unlimited and always free.** They are the
/// habit we want to form — a meter on them would make people record less,
/// which is exactly backwards. Only chatting with ARCA draws down credit,
/// because that is where the per-message model cost lives and where a heavy
/// user can run up a real bill.
///
/// **This ledger is client-side and advisory.** It exists so onboarding can
/// promise a concrete amount and the app can show what's left. It is not a
/// spending control — anyone can reset it by reinstalling. When the ARCA Cloud
/// proxy lands the server becomes authoritative and this becomes a cache of
/// the balance it reports; keep the shape stable so that swap is a transport
/// change rather than a redesign.
public enum TrialCredit {
    /// What a new account is granted, in USD.
    public static let grantUSD: Double = 5.00

    /// Cost of one chat exchange — the user's message plus ARCA's reply,
    /// against the conversation so far. Derived from measured usage
    /// (2026-08-05): 54 Sonnet 5 calls cost $2.74 across 592K input and 65K
    /// output tokens, so about $0.05 per exchange. Re-derive this from
    /// `ai-usage.jsonl` rather than adjusting it by feel.
    public static let usdPerChatMessage: Double = 0.05

    private static let grantedKey = "trialCreditGrantedUSD"
    private static let spentKey = "trialCreditSpentUSD"

    /// Grants the opening balance once per account. Later calls are no-ops, so
    /// re-running onboarding can't mint more credit.
    public static func grantIfNeeded() {
        guard granted() == 0 else { return }
        AccountDefaults.set(String(grantUSD), for: grantedKey)
    }

    public static func granted() -> Double {
        Double(AccountDefaults.string(grantedKey) ?? "") ?? 0
    }

    public static func spent() -> Double {
        Double(AccountDefaults.string(spentKey) ?? "") ?? 0
    }

    public static func remainingUSD() -> Double {
        max(0, granted() - spent())
    }

    /// Chat exchanges the remaining balance still buys.
    public static func remainingMessages() -> Int {
        Int((remainingUSD() / usdPerChatMessage).rounded(.down))
    }

    /// Exchanges the full grant buys — the number onboarding advertises.
    public static var grantMessages: Int {
        Int((grantUSD / usdPerChatMessage).rounded(.down))
    }

    public static func hasBalance() -> Bool {
        remainingUSD() > 0
    }

    /// Bills one chat exchange. Recording never calls this.
    public static func consumeChatMessage() {
        AccountDefaults.set(String(spent() + usdPerChatMessage), for: spentKey)
    }

    /// Remaining balance for the chat meter — "대화 87번".
    public static func remainingLabel() -> String {
        "대화 \(remainingMessages())번"
    }

    /// Same phrasing for the full grant, so onboarding and the meter agree.
    public static func grantLabel() -> String {
        "대화 \(grantMessages)번"
    }
}
