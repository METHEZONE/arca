import Foundation
import Speech
import AVFoundation
import ArcaVoiceCore

/// Live streaming transcription on Apple's SpeechAnalyzer/SpeechTranscriber
/// (macOS 26 / iOS 26). Emits volatile segments that settle into finalized ones —
/// the UI animates that stabilization. Models are OS-managed; the first use of a
/// locale may download an asset.
public final class AppleLiveTranscriber: LiveTranscriber {
    public init() {}

    public static func isLocaleSupported(_ locale: Locale) async -> Bool {
        let supported = await SpeechTranscriber.supportedLocales
        return supported.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    public func transcribe(_ buffers: AsyncStream<CapturedBuffer>, channel: CaptureChannel, locale: Locale)
        -> AsyncThrowingStream<LiveSegment, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let transcriber = SpeechTranscriber(
                        locale: locale,
                        transcriptionOptions: [],
                        reportingOptions: [.volatileResults],
                        attributeOptions: [.audioTimeRange]
                    )
                    try await Self.ensureModel(for: transcriber, locale: locale)

                    let analyzer = SpeechAnalyzer(modules: [transcriber])
                    guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                        compatibleWith: [transcriber]) else {
                        throw TranscribeError.noCompatibleAudioFormat
                    }

                    let (inputStream, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()

                    // Volatile results share an ID window; we reuse one UUID until
                    // a finalized result closes it so the UI can animate in place.
                    let resultsTask = Task {
                        var volatileID = UUID()
                        for try await result in transcriber.results {
                            let text = String(result.text.characters)
                            guard !text.isEmpty else { continue }
                            let (start, end) = Self.timeRange(of: result.text)
                            let segment = LiveSegment(
                                id: volatileID,
                                channel: channel,
                                text: text,
                                start: start,
                                end: end,
                                isVolatile: !result.isFinal
                            )
                            continuation.yield(segment)
                            if result.isFinal {
                                volatileID = UUID()
                            }
                        }
                    }

                    try await analyzer.start(inputSequence: inputStream)

                    let converter = BufferConverter()
                    for await captured in buffers {
                        if Task.isCancelled { break }
                        let converted = try converter.convert(captured.buffer, to: analyzerFormat)
                        inputBuilder.yield(AnalyzerInput(buffer: converted))
                    }
                    inputBuilder.finish()
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                    _ = try? await resultsTask.value
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func timeRange(of text: AttributedString) -> (TimeInterval, TimeInterval) {
        var start = TimeInterval.greatestFiniteMagnitude
        var end: TimeInterval = 0
        for run in text.runs {
            if let range = run.audioTimeRange {
                start = min(start, range.start.seconds)
                end = max(end, range.end.seconds)
            }
        }
        if start == .greatestFiniteMagnitude { start = 0 }
        return (start, end)
    }

    private static func ensureModel(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw TranscribeError.localeNotSupported(locale.identifier)
        }

        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            try await AssetInventory.reserve(locale: locale)
        }
    }
}

public enum TranscribeError: Error, LocalizedError {
    case noCompatibleAudioFormat
    case localeNotSupported(String)

    public var errorDescription: String? {
        switch self {
        case .noCompatibleAudioFormat:
            return "No audio format compatible with the transcription engine"
        case .localeNotSupported(let identifier):
            return "On-device transcription on this device doesn't support \(identifier)"
        }
    }
}
