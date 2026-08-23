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

    static func processingPipeline() -> ProcessingPipeline? {
        guard let openAIKey = KeychainStore.get(.openAI), !openAIKey.isEmpty else { return nil }
        return ProcessingPipeline(
            finalTranscriber: OpenAIDiarizedTranscriber(apiKey: openAIKey),
            summarizer: summarizer()
        )
    }
}
