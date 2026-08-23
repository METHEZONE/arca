import Foundation
import ArcaVoiceKit

/// Builds the processing engines from user-owned keys (BYOK, Keychain-stored).
enum EngineFactory {
    static var hasFinalPassKey: Bool {
        KeychainStore.get(.openAI)?.isEmpty == false
    }

    static var hasSummarizerKey: Bool {
        KeychainStore.get(.anthropic)?.isEmpty == false || KeychainStore.get(.openAI)?.isEmpty == false
    }

    /// The summarizer for whichever key(s) are actually configured.
    ///
    /// Deliberately independent of the OpenAI key: summarizing a transcript that
    /// already exists needs no transcription, so an Anthropic-only user must not
    /// be left with nothing. (Transcription still requires OpenAI — see
    /// `processingPipeline()`.)
    static func summarizer() -> (any Summarizer)? {
        let anthropicKey = KeychainStore.get(.anthropic).flatMap { $0.isEmpty ? nil : $0 }
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

    /// The final-pass pipeline.
    ///
    /// Transcription is a chain, not a single provider: the cloud pass first,
    /// then Apple's on-device recognizer over the saved file. Before that chain
    /// existed, `OpenAIDiarizedTranscriber` was the only implementation, so a
    /// dead key or an outage meant no transcript and — because the pipeline threw
    /// before summarization — no notes either.
    ///
    /// - Parameter includeOnDeviceFallback: pass `false` when the caller already
    ///   holds a usable live transcript for this session. Re-running on-device
    ///   recognition over audio that was already recognized in real time is pure
    ///   duplicated work; promoting the stored segments is free. See
    ///   `FinalPassRunner`, which makes that call per session.
    static func processingPipeline(includeOnDeviceFallback: Bool = true) -> ProcessingPipeline? {
        let openAIKey = KeychainStore.get(.openAI).flatMap { $0.isEmpty ? nil : $0 }
        let onDevice = { AppleFileTranscriber(locale: TranscriptionPrefs.liveLocale) }

        let transcriber: any FinalTranscriber
        switch (openAIKey, includeOnDeviceFallback) {
        case let (key?, true):
            transcriber = FallbackTranscriber(
                primary: OpenAIDiarizedTranscriber(apiKey: key),
                fallback: onDevice(),
                log: { DebugTrace.log($0) })
        case let (key?, false):
            transcriber = OpenAIDiarizedTranscriber(apiKey: key)
        case (nil, true):
            transcriber = onDevice()
        case (nil, false):
            return nil
        }
        return ProcessingPipeline(finalTranscriber: transcriber, summarizer: summarizer())
    }
}
