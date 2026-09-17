import Foundation
import ArcaVoiceKit

/// Reads the transcription-language preference. "auto" = 한·영 혼용: the live
/// pass runs Korean on-device, the final pass takes its hint from ARCA's own
/// language setting.
///
/// "auto" used to send no hint at all, on the theory that the cloud model would
/// detect the language per segment and handle code-switching. Measured, it does
/// the opposite: unhinted, whisper decides Korean room audio is English and
/// loops on hallucinated phrases. A hint is worth more than per-segment
/// switching, so there is always one.
///
/// The hint follows ARCA's language, not the OS language: a Korean user on an
/// English macOS got `language=en`, and with a wrong hint whisper doesn't
/// transcribe, it *translates* — a Korean meeting came back as fluent English.
enum TranscriptionPrefs {
    static var storedValue: String {
        UserDefaults.standard.string(forKey: "transcribeLocale") ?? "auto"
    }

    static var liveLocale: Locale {
        switch storedValue {
        case "auto", "ko-KR": return Locale(identifier: "ko-KR")
        default: return Locale(identifier: storedValue)
        }
    }

    static var languageHints: [String] {
        if storedValue == "auto" { return [appLanguage] }
        if let code = Locale(identifier: storedValue).language.languageCode?.identifier {
            return [code]
        }
        return [appLanguage]
    }

    /// ARCA's UI language as a bare code ("ko", "en") — the language the user
    /// chose for ARCA, which is also the language they speak in meetings.
    private static var appLanguage: String {
        if ArcaLanguageResolver.isKorean { return "ko" }
        return Locale.preferredLanguages.first
            .flatMap { Locale(identifier: $0).language.languageCode?.identifier }
            ?? "en"
    }
}
