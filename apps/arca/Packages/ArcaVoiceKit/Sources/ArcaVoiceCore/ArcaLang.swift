import Foundation

/// The app's display language, as the prompt layer sees it.
///
/// One setting, one key: this reads the same `appLanguage` default that
/// `ArcaLanguageResolver` owns (see `ArcaLocalization.swift`), so the language
/// picked in Settings is the language generated content comes back in. It
/// stays a separate type only because LLM prompts want a two-letter code and a
/// language *name*, which the view-facing resolver has no business carrying.
public enum ArcaLang {
    /// UserDefaults key for the setting. Shared with `ArcaLanguageResolver`.
    public static let defaultsKey = ArcaLanguageResolver.defaultsKey

    /// Resolved two-letter code, "ko" or "en". Read live rather than off the
    /// resolver's cache, so a default written directly (tests, a defaults
    /// import) is honored without an `apply(_:)` round trip.
    public static var code: String {
        ArcaLanguageResolver.resolve(ArcaLanguageResolver.stored()) ? "ko" : "en"
    }

    public static var isKorean: Bool { code == "ko" }

    /// The language name LLM prompts should ask for ("Korean" / "English").
    public static var promptLanguageName: String { isKorean ? "Korean" : "English" }
}

/// English-first spelling of `L(_:_:)`, kept so the call sites written that way
/// keep reading naturally — `L("Tasks", ko: "할 일")`. Same resolver, same
/// answer, just the other argument order.
public func L(_ en: String, ko: String) -> String {
    ArcaLang.isKorean ? ko : en
}
