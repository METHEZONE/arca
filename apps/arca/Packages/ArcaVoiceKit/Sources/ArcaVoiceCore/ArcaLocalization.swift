import Foundation

/// How ARCA decides which language to speak.
///
/// **Why a helper instead of a String Catalog.** The proper Apple answer is
/// `Localizable.xcstrings` with `Text("key")` lookups. The problem is the starting
/// state: the Mac companion was written in Korean literals and the iPhone in
/// English ones, several hundred strings in total, and this project generates its
/// Xcode project from `project.yml` with no GUI step — so adopting a catalog means
/// hand-authoring a large JSON file *and* rewriting every literal into a key
/// before a single user sees a difference.
///
/// `L("한국어", "English")` gets the actual outcome now — one surface reads one
/// language on both platforms, following the device — and keeps both versions side
/// by side in the source where a mismatch is obvious in review. What it gives up:
/// App Store localization metadata (separate anyway) and plural rules (Korean
/// doesn't inflect; the few English counts are written out by hand).
///
/// Migrating to a catalog later is mechanical: every `L(ko, en)` call site is
/// already a complete translation pair.
///
/// **Why this lives in the core package rather than the app.** User-facing copy
/// isn't only in views — score labels, formatted durations and error messages are
/// computed in `Vitals` and `Intelligence`, and they have to speak the same
/// language as the screen around them. Keeping the resolver here is what lets
/// `VitalsScoring.readinessLabel` be bilingual at all.
public enum ArcaLanguageChoice: String, CaseIterable, Identifiable, Sendable {
    case system, korean, english
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: return L("기기 설정 따라가기", "Follow device setting")
        case .korean: return "한국어"
        case .english: return "English"
        }
    }
}

/// The actual lookup. Free of actor isolation so `L(_:_:)` costs a `Bool` read.
public enum ArcaLanguageResolver {
    public static let defaultsKey = "appLanguage"

    /// Written only from the main actor when the user changes the setting; a
    /// `Bool` read cannot tear, so unsynchronised reads are safe.
    nonisolated(unsafe) private static var cachedIsKorean = resolve(stored())

    public static var isKorean: Bool { cachedIsKorean }

    public static func stored() -> ArcaLanguageChoice {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        return ArcaLanguageChoice(rawValue: raw) ?? .system
    }

    public static func apply(_ choice: ArcaLanguageChoice) {
        UserDefaults.standard.set(choice.rawValue, forKey: defaultsKey)
        cachedIsKorean = resolve(choice)
    }

    public static func resolve(_ choice: ArcaLanguageChoice) -> Bool {
        switch choice {
        case .korean: return true
        case .english: return false
        case .system:
            // `preferredLanguages` is the user's ordered list already filtered
            // against what the app claims to support, so the first entry is the
            // one the system actually wants us to use.
            return (Locale.preferredLanguages.first ?? "en").hasPrefix("ko")
        }
    }

    /// Locale to hand to date/number formatters so they agree with the copy.
    public static var formatterLocale: Locale {
        Locale(identifier: isKorean ? "ko_KR" : "en_US")
    }
}

/// The Korean string when ARCA is speaking Korean, otherwise the English one.
///
/// Deliberately terse and global: it appears hundreds of times, and a longer name
/// would make every view harder to read than the copy it wraps.
public func L(_ ko: String, _ en: String) -> String {
    ArcaLanguageResolver.isKorean ? ko : en
}
