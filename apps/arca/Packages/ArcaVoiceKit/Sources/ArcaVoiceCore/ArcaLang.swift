import Foundation

/// The app's display language. "system" follows the OS (Korean-first devices
/// get Korean); "ko"/"en" pin it. UI strings go through `L(_:ko:)`, and LLM
/// prompts read `promptLanguageName` so generated content (task titles,
/// briefings, approval questions) lands in the user's language too.
public enum ArcaLang {
    /// UserDefaults key for the setting: "system" | "ko" | "en".
    public static let defaultsKey = "appLanguage"

    /// Resolved two-letter code, "ko" or "en".
    public static var code: String {
        switch UserDefaults.standard.string(forKey: defaultsKey) {
        case "ko": return "ko"
        case "en": return "en"
        default:
            return Locale.preferredLanguages.first?.hasPrefix("ko") == true ? "ko" : "en"
        }
    }

    public static var isKorean: Bool { code == "ko" }

    /// The language name LLM prompts should ask for ("Korean" / "English").
    public static var promptLanguageName: String { isKorean ? "Korean" : "English" }
}

/// Pick the string for the current app language. Reads inline at the call
/// site — `L("Tasks", ko: "할 일")` — so every string shows both languages
/// where it's used.
public func L(_ en: String, ko: String) -> String {
    ArcaLang.isKorean ? ko : en
}
