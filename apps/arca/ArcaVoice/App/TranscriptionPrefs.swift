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

    /// The file pass and anything without a live transcript: the language the
    /// last recording turned out to be in, else the first candidate.
    static var liveLocale: Locale {
        switch storedValue {
        case "auto": return detectedLocale ?? liveCandidates.first ?? Locale(identifier: "ko-KR")
        default: return Locale(identifier: storedValue)
        }
    }

    /// "auto": languages to try at once at the start of a recording
    /// (`AutoLanguageTranscriber`) — ARCA's language first (ties go to it),
    /// then the device's languages, then whichever of Korean/English is still
    /// missing, so a Korean speaker on an English iPhone (or the reverse) is
    /// covered. Two at most: each is a recognizer running for the first 20 s.
    ///
    /// "The one heard last time" used to lead. One recording that opened on
    /// silence or English then won every tie after it, and its language went
    /// to whisper as the hint — testers got fluent nonsense transcripts.
    static var liveCandidates: [Locale] {
        guard storedValue == "auto" else { return [liveLocale] }
        var codes: [String] = []
        for code in [appLanguage]
            + Locale.preferredLanguages.compactMap({ Locale(identifier: $0).language.languageCode?.identifier })
            + ["ko", "en"] where !codes.contains(code) {
            codes.append(code)
        }
        return codes.prefix(2).map(recognizerLocale(for:))
    }

    static func rememberDetected(_ locale: Locale) {
        UserDefaults.standard.set(locale.identifier, forKey: detectedKey)
    }

    /// Called as a recording starts: the hint must describe this recording,
    /// not an earlier one. Undecided (short) recordings hint ARCA's language.
    static func forgetDetected() {
        UserDefaults.standard.removeObject(forKey: detectedKey)
    }

    private static let detectedKey = "detectedSpeechLocale"

    private static var detectedLocale: Locale? {
        UserDefaults.standard.string(forKey: detectedKey).map(Locale.init(identifier:))
    }

    /// A bare language → the region its recognizer is published under.
    private static func recognizerLocale(for code: String) -> Locale {
        let regions = ["ko": "ko-KR", "en": "en-US", "ja": "ja-JP", "zh": "zh-CN", "es": "es-ES",
                       "fr": "fr-FR", "de": "de-DE", "it": "it-IT", "pt": "pt-BR", "vi": "vi-VN"]
        return Locale(identifier: regions[code] ?? code)
    }

    static var languageHints: [String] {
        if storedValue == "auto" {
            return [detectedLocale?.language.languageCode?.identifier ?? appLanguage]
        }
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
