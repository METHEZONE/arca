import Foundation
import ArcaVoiceKit

/// Which engine runs the post-recording transcription pass.
enum TranscriptionEngine: String, CaseIterable, Identifiable, Sendable {
    /// Apple's on-device engine. Free, offline, no diarization.
    case localFree
    /// OpenAI's diarized model. Paid per minute of audio, per channel.
    case cloudDiarized

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localFree: return L("기기에서 (무료)", "On this device (free)")
        case .cloudDiarized: return L("클라우드 화자분리 (유료)", "Cloud with speaker separation (paid)")
        }
    }

    var detail: String {
        switch self {
        case .localFree:
            return L("애플 온디바이스 엔진. 비용 0원, 와이파이 없어도 되고 오디오가 기기 밖으로 나가지 않아요. 마이크와 상대 소리를 따로 녹음하니 '나 / 상대'는 그대로 구분돼요. 상대가 여러 명일 때 그들끼리 나누지는 못해요.",
                     "Apple's on-device engine. Costs nothing, needs no network, and the audio never leaves the Mac. Mic and system audio are recorded separately, so you still get \"me / them\" — it just can't split several remote speakers from each other.")
        case .cloudDiarized:
            return L("오디오를 OpenAI로 보내 화자별로 나눠요. 오디오 분 단위로 과금되고, 마이크·시스템 채널이 각각 청구돼요.",
                     "Sends the audio to OpenAI and splits it by speaker. Billed per minute of audio, and the mic and system channels are billed separately.")
        }
    }
}

/// Builds the processing engines from user-owned keys (BYOK, Keychain-stored).
enum EngineFactory {
    static let engineDefaultsKey = "transcriptionEngine"

    static var hasFinalPassKey: Bool {
        KeychainStore.get(.openAI)?.isEmpty == false
    }

    static var hasSummarizerKey: Bool {
        ArcaCloud.anthropicKey?.isEmpty == false || KeychainStore.get(.openAI)?.isEmpty == false
    }

    /// Defaults to the free engine. Transcription is by far the largest line on
    /// the bill — an hour of two-channel meeting is two billable hours — and the
    /// device can already do it for nothing, so paying is the opt-in.
    static var transcriptionEngine: TranscriptionEngine {
        get {
            UserDefaults.standard.string(forKey: engineDefaultsKey)
                .flatMap(TranscriptionEngine.init(rawValue:)) ?? .localFree
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: engineDefaultsKey) }
    }

    /// - Parameter engine: overrides the stored preference for one run, so a
    ///   single recording can be sent for paid diarization without changing the
    ///   default for everything else.
    static func processingPipeline(engine: TranscriptionEngine? = nil) -> ProcessingPipeline? {
        let openAIKey = KeychainStore.get(.openAI).flatMap { $0.isEmpty ? nil : $0 }
        let anthropicKey = ArcaCloud.anthropicKey.flatMap { $0.isEmpty ? nil : $0 }

        let finalTranscriber: any FinalTranscriber
        switch engine ?? transcriptionEngine {
        case .localFree:
            // The same locale the live pass already transcribes with, rather
            // than the cloud model's language hints — those can be empty (the
            // "auto" setting) or bare like "ko", and the on-device engine wants
            // a locale it actually publishes.
            if #available(macOS 26.0, iOS 26.0, *), !UserDefaults.standard.bool(forKey: "legacySpeech") {
                finalTranscriber = AppleFileTranscriber(locale: TranscriptionPrefs.liveLocale)
            } else {
                finalTranscriber = LegacyFileTranscriber(locale: TranscriptionPrefs.liveLocale)
            }
        case .cloudDiarized:
            guard let openAIKey else { return nil }
            finalTranscriber = OpenAIDiarizedTranscriber(apiKey: openAIKey)
        }

        // Optional on purpose: with the local engine and no keys at all, ARCA
        // still transcribes. Losing the summary is a smaller loss than losing
        // the words, and the pipeline already treats notes as optional.
        var summarizer: (any Summarizer)?
        switch (anthropicKey, openAIKey) {
        case let (.some(anthropic), .some(openAI)):
            summarizer = FallbackSummarizer(
                primary: ClaudeSummarizer(apiKey: anthropic),
                fallback: OpenAISummarizer(apiKey: openAI))
        case let (.some(anthropic), .none):
            summarizer = ClaudeSummarizer(apiKey: anthropic)
        case let (.none, .some(openAI)):
            summarizer = OpenAISummarizer(apiKey: openAI)
        case (.none, .none):
            summarizer = nil
        }
        return ProcessingPipeline(finalTranscriber: finalTranscriber, summarizer: summarizer)
    }
}
