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

    static func processingPipeline() -> ProcessingPipeline? {
        guard let openAIKey = KeychainStore.get(.openAI), !openAIKey.isEmpty else { return nil }
        let finalTranscriber = OpenAIDiarizedTranscriber(apiKey: openAIKey)
        let openAISummarizer = OpenAISummarizer(apiKey: openAIKey)
        let summarizer: any Summarizer
        if let anthropicKey = KeychainStore.get(.anthropic), !anthropicKey.isEmpty {
            summarizer = FallbackSummarizer(
                primary: ClaudeSummarizer(apiKey: anthropicKey),
                fallback: openAISummarizer
            )
        } else {
            summarizer = openAISummarizer
        }
        return ProcessingPipeline(finalTranscriber: finalTranscriber, summarizer: summarizer)
    }
}
