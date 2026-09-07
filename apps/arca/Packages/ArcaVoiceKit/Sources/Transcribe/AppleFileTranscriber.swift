import Foundation
import Speech
import AVFoundation
import ArcaVoiceCore

/// The free, on-device, offline final pass.
///
/// Same engine as the live transcriber (`SpeechAnalyzer`/`SpeechTranscriber`),
/// but run over a finished file instead of a microphone stream, so a recording
/// can be re-transcribed at any time at zero cost and with no network.
///
/// What it does not do is diarize: it cannot tell two voices apart inside one
/// audio file. In practice that matters less than it sounds, because ARCA
/// records the microphone and the system output as separate channels — "me" and
/// "them" are already separated by construction, for free. The paid diarized
/// pass only adds the ability to split several remote speakers apart from each
/// other within the system channel.
@available(macOS 26.0, iOS 26.0, *)
public struct AppleFileTranscriber: FinalTranscriber {
    private let locale: Locale?

    /// - Parameter locale: overrides the language hint; `nil` follows the hint
    ///   passed to `transcribe`, then the current locale.
    public init(locale: Locale? = nil) {
        self.locale = locale
    }

    public func transcribe(fileURL: URL, channel: CaptureChannel,
                           hints: TranscriptHints) async throws -> Transcript {
        let resolved = try await Self.resolveLocale(preferred: locale, hints: hints)

        let transcriber = SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            // No volatile results: nothing is watching this one live, and the
            // partials would just be discarded.
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        try await Self.installAssets(for: transcriber, locale: resolved)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        // Attendee names and jargon, handed to the recognizer as contextual
        // strings. This is the one lever that makes knowing who is in the room
        // pay off on the free engine: it can't tell voices apart, but told that
        // "박민성" and "스파크랩" are expected, it stops inventing homophones for
        // them — which is most of what makes an on-device Korean transcript
        // read badly.
        try await Self.applyVocabulary(hints.vocabulary, to: analyzer)
        let file = try AVAudioFile(forReading: fileURL)

        // Started before the analyzer runs: results stream out as the file is
        // consumed, and attaching afterwards would miss the early ones.
        let collector = Task { () -> [Transcript.Segment] in
            var segments: [Transcript.Segment] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let (start, end) = AppleLiveTranscriber.timeRange(of: result.text)
                segments.append(Transcript.Segment(
                    text: text, start: start, end: end,
                    // No confidence and no speaker label: this engine reports
                    // neither, and inventing a "S1" would imply a diarization
                    // that never happened.
                    confidence: nil, speakerLabel: nil))
            }
            return segments
        }

        do {
            _ = try await analyzer.analyzeSequence(from: file)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            throw error
        }

        let segments = try await collector.value
        return Transcript(channel: channel,
                          segments: segments.sorted { $0.start < $1.start },
                          languageCode: resolved.identifier)
    }

    /// Picks a locale the on-device engine will actually accept.
    ///
    /// The caller's hints are written for the cloud model, where a bare `"ko"`
    /// or an empty list is fine. Handing either straight to `SpeechTranscriber`
    /// is not: it wants a locale from its own supported list, and anything else
    /// fails at reservation time with "unsupported locale" — which is what a
    /// whole recovery run died on. So every candidate is matched against the
    /// real list, exactly first and then by language, before it's used.
    static func resolveLocale(preferred: Locale?, hints: TranscriptHints) async throws -> Locale {
        let supported = await SpeechTranscriber.supportedLocales

        func match(_ candidate: Locale) -> Locale? {
            if let exact = supported.first(where: {
                $0.identifier(.bcp47) == candidate.identifier(.bcp47)
            }) { return exact }
            // "ko" should find "ko-KR": the region is the engine's to choose.
            guard let language = candidate.language.languageCode?.identifier else { return nil }
            return supported.first { $0.language.languageCode?.identifier == language }
        }

        for candidate in [preferred, Locale.current].compactMap({ $0 }) {
            if let hit = match(candidate) { return hit }
        }
        for code in hints.languageCodes {
            if let hit = match(Locale(identifier: code)) { return hit }
        }
        // English is the near-universal fallback; without it there is nothing to
        // run at all, and a wrong-language attempt still beats a hard failure.
        if let english = supported.first(where: {
            $0.language.languageCode?.identifier == "en"
        }) { return english }
        guard let any = supported.first else {
            throw TranscribeError.localeNotSupported(
                (preferred ?? Locale.current).identifier)
        }
        return any
    }

    /// Feeds expected words to the recognizer, best-effort.
    ///
    /// Shared with the live transcriber so a name typed before the meeting helps
    /// both the transcript that appears while recording and the one rebuilt
    /// afterwards. A context that the engine rejects must not sink the run —
    /// a slightly worse transcript beats no transcript.
    static func applyVocabulary(_ vocabulary: [String], to analyzer: SpeechAnalyzer) async throws {
        let terms = vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return }
        let context = AnalysisContext()
        context.contextualStrings[.general] = Array(Set(terms)).sorted()
        try? await analyzer.setContext(context)
    }

    /// Downloads the model, and treats reservation as best-effort.
    ///
    /// Reserving only pins the asset so the OS won't evict it. It can fail when
    /// the reservation slots are full — and a failure there says nothing about
    /// whether transcription would have worked, so it must not abort the run.
    static func installAssets(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            try? await AssetInventory.reserve(locale: locale)
        }
    }
}
