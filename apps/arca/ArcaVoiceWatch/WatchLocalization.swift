import Foundation

/// The watch app's own copy of the language helper.
///
/// Duplicated rather than shared on purpose: the watch target deliberately links
/// no package (`ArcaVoiceKit` pulls in ScreenCaptureKit and CoreAudio code that
/// has no business on a watch), so it cannot see `ArcaVoiceCore`'s version. It
/// reads the same `UserDefaults` key, but note that the watch has its own defaults
/// domain — a language chosen on the phone does not propagate here, so the watch
/// follows its own system language unless the user overrides it on the watch. That
/// matches how the wrist behaves for every other system setting.
enum WatchLanguage {
    private static let defaultsKey = "appLanguage"

    static var isKorean: Bool {
        switch UserDefaults.standard.string(forKey: defaultsKey) {
        case "korean": return true
        case "english": return false
        default: return (Locale.preferredLanguages.first ?? "en").hasPrefix("ko")
        }
    }
}

/// Same signature as the app's helper, so copy reads identically in both trees.
func L(_ ko: String, _ en: String) -> String {
    WatchLanguage.isKorean ? ko : en
}
