import Foundation

/// Reads the transcription-language preference. "auto" = 한·영 혼용: the live
/// pass runs Korean on-device, the final pass takes its hint from the device
/// language.
///
/// "auto" used to send no hint at all, on the theory that the cloud model would
/// detect the language per segment and handle code-switching. Measured, it does
/// the opposite: unhinted, whisper decides Korean room audio is English and
/// loops on hallucinated phrases. A hint is worth more than per-segment
/// switching, so there is always one.
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
        if storedValue == "auto" { return [deviceLanguage] }
        if let code = Locale(identifier: storedValue).language.languageCode?.identifier {
            return [code]
        }
        return [deviceLanguage]
    }

    /// The language the phone/Mac is set to, as a bare code ("ko", "en").
    private static var deviceLanguage: String {
        Locale.preferredLanguages.first
            .flatMap { Locale(identifier: $0).language.languageCode?.identifier }
            ?? "ko"
    }
}
