import Foundation

/// Reads the transcription-language preference. "auto" = 한·영 혼용: the live
/// pass runs Korean on-device, the final pass omits the language hint so the
/// cloud model auto-detects per segment (best for code-switched speech).
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
        switch storedValue {
        case "auto": return []
        case "ko-KR": return ["ko"]
        case "en-US": return ["en"]
        default: return []
        }
    }
}
