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

    /// The summarizer for whichever key(s) are actually configured.
    ///
    /// Deliberately independent of the OpenAI key: summarizing a transcript that
    /// already exists needs no transcription, so an Anthropic-only user must not
    /// be left with nothing. Optional on purpose — with the local engine and no
    /// keys at all ARCA still transcribes, and losing the summary is a smaller
    /// loss than losing the words.
    static func summarizer() -> (any Summarizer)? {
        let anthropicKey = ArcaCloud.anthropicKey.flatMap { $0.isEmpty ? nil : $0 }
        let openAIKey = KeychainStore.get(.openAI).flatMap { $0.isEmpty ? nil : $0 }
        switch (anthropicKey, openAIKey) {
        case let (anthropic?, openAI?):
            return FallbackSummarizer(
                primary: ClaudeSummarizer(apiKey: anthropic),
                fallback: OpenAISummarizer(apiKey: openAI)
            )
        case let (anthropic?, nil):
            return ClaudeSummarizer(apiKey: anthropic)
        case let (nil, openAI?):
            return OpenAISummarizer(apiKey: openAI)
        case (nil, nil):
            return nil
        }
    }

    /// Apple's on-device file transcriber for this OS. SpeechAnalyzer only
    /// exists on macOS 26 / iOS 26, so anything older (and anyone who ticked
    /// `legacySpeech`) gets `SFSpeechRecognizer` instead.
    private static func onDeviceTranscriber() -> any FinalTranscriber {
        if #available(macOS 26.0, iOS 26.0, *), !UserDefaults.standard.bool(forKey: "legacySpeech") {
            // The same locale the live pass already transcribes with, rather
            // than the cloud model's language hints — those can be empty (the
            // "auto" setting) or bare like "ko", and the on-device engine wants
            // a locale it actually publishes.
            return AppleFileTranscriber(locale: TranscriptionPrefs.liveLocale)
        }
        return LegacyFileTranscriber(locale: TranscriptionPrefs.liveLocale)
    }

    /// The final-pass pipeline.
    ///
    /// On the paid engine transcription is a chain, not a single provider: the
    /// cloud pass first, then Apple's on-device recognizer over the saved file.
    /// Before that chain existed, a dead key or an outage meant no transcript
    /// and — because the pipeline threw before summarization — no notes either.
    ///
    /// - Parameter engine: overrides the stored preference for one run, so a
    ///   single recording can be sent for paid diarization without changing the
    ///   default for everything else.
    /// - Parameter includeOnDeviceFallback: pass `false` when the caller already
    ///   holds a usable live transcript for this session. Re-running on-device
    ///   recognition over audio that was already recognized in real time is pure
    ///   duplicated work; promoting the stored segments is free. See
    ///   `FinalPassRunner`, which makes that call per session.
    static func processingPipeline(engine: TranscriptionEngine? = nil,
                                   includeOnDeviceFallback: Bool = true) -> ProcessingPipeline? {
        let openAIKey = KeychainStore.get(.openAI).flatMap { $0.isEmpty ? nil : $0 }

        let finalTranscriber: any FinalTranscriber
        switch (engine ?? transcriptionEngine, includeOnDeviceFallback) {
        case (.localFree, true):
            finalTranscriber = onDeviceTranscriber()
        case (.localFree, false):
            // Nothing left to run: the on-device pass is the only engine here
            // and its output is already in the store. The caller summarizes the
            // live transcript instead of paying to redo it.
            return nil
        case let (.cloudDiarized, includeFallback):
            guard let openAIKey else { return nil }
            let cloud = OpenAIDiarizedTranscriber(apiKey: openAIKey)
            finalTranscriber = includeFallback
                ? FallbackTranscriber(primary: cloud,
                                      fallback: onDeviceTranscriber(),
                                      log: { DebugTrace.log($0) })
                : cloud
        }
        return ProcessingPipeline(finalTranscriber: finalTranscriber, summarizer: summarizer())
    }
}
