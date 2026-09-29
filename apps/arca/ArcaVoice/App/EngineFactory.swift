import Foundation
import ArcaVoiceKit

/// Which engine runs the post-recording transcription pass.
enum TranscriptionEngine: String, CaseIterable, Identifiable, Sendable {
    /// Apple's on-device engine. Free, offline, no diarization.
    case localFree
    /// Whisper through ARCA Cloud (or the user's own OpenAI key), with speakers
    /// worked out from the conversation. The raw value predates both.
    case cloudDiarized

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localFree: return L("기기에서 (무료)", "On this device (free)")
        case .cloudDiarized: return L("클라우드 (더 정확하게)", "Cloud (more accurate)")
        }
    }

    var detail: String {
        switch self {
        case .localFree:
            return L("애플 온디바이스 엔진. 비용 0원, 와이파이 없어도 되고 오디오가 기기 밖으로 나가지 않아요. 마이크와 상대 소리를 따로 녹음하니 '나 / 상대'는 그대로 구분돼요. 상대가 여러 명일 때 그들끼리 나누지는 못해요.",
                     "Apple's on-device engine. Costs nothing, needs no network, and the audio never leaves the Mac. Mic and system audio are recorded separately, so you still get \"me / them\" — it just can't split several remote speakers from each other.")
        case .cloudDiarized:
            return L("녹음이 끝나면 오디오를 ARCA 클라우드(OpenAI 음성 인식)로 보내 한국어와 영어를 더 정확하게 받아적어요. 누가 말했는지는 대화 맥락으로 나눠요. 인터넷이 없으면 기기에서 만든 전사를 먼저 쓰고, 연결되면 다시 시도해요.",
                     "When a recording ends, ARCA sends the audio to ARCA Cloud (OpenAI speech recognition) for a more accurate Korean and English transcript, and works out who said what from the conversation. Offline, the on-device transcript is used first and the cloud pass retries once you're connected.")
        }
    }
}

/// Builds the processing engines from user-owned keys (BYOK, Keychain-stored).
enum EngineFactory {
    static let engineDefaultsKey = "transcriptionEngine"

    /// Whether the cloud pass can run: the user's own OpenAI key, or an ARCA
    /// Cloud grant (an invite, or the free tier every install enrolls in).
    static var hasFinalPassKey: Bool {
        cloudTranscriber() != nil
    }

    static var hasSummarizerKey: Bool {
        ArcaCloud.anthropicKey?.isEmpty == false || KeychainStore.get(.openAI)?.isEmpty == false
    }

    /// Defaults to the cloud pass whenever it can run. The on-device engine
    /// hears one language per recording and trips over Korean-English
    /// code-switching; people keep ARCA for the words, so accuracy is the
    /// default and the free engine is one tap away. Whatever the user picked
    /// themselves stays picked.
    static var transcriptionEngine: TranscriptionEngine {
        get {
            UserDefaults.standard.string(forKey: engineDefaultsKey)
                .flatMap(TranscriptionEngine.init(rawValue:))
                ?? (hasFinalPassKey ? .cloudDiarized : .localFree)
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: engineDefaultsKey) }
    }

    /// Whisper with the user's own key, else through ARCA Cloud on the invite
    /// code. nil when neither exists.
    static func cloudTranscriber() -> OpenAIDiarizedTranscriber? {
        if let key = KeychainStore.get(.openAI), !key.isEmpty {
            return OpenAIDiarizedTranscriber(apiKey: key)
        }
        if let invite = ArcaCloud.inviteToken {
            return OpenAIDiarizedTranscriber(
                apiKey: invite,
                endpoint: ArcaCloud.baseURL.deletingLastPathComponent().appendingPathComponent("transcribe"),
                auth: .arcaCloud)
        }
        return nil
    }

    /// Works out who said what from the conversation — the only speaker
    /// separation a single iPhone microphone can get.
    static func speakerAttributor() -> (any SpeakerAttributor)? {
        guard let key = ArcaCloud.anthropicKey, !key.isEmpty else { return nil }
        return ClaudeSpeakerAttributor(apiKey: key)
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
            guard let cloud = cloudTranscriber() else { return nil }
            finalTranscriber = includeFallback
                ? FallbackTranscriber(primary: cloud,
                                      fallback: onDeviceTranscriber(),
                                      log: { DebugTrace.log($0) })
                : cloud
        }
        return ProcessingPipeline(finalTranscriber: finalTranscriber, summarizer: summarizer(),
                                  speakerAttributor: speakerAttributor())
    }
}
