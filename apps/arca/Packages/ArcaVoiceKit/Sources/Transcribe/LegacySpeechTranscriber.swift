import Foundation
import Speech
import AVFoundation
import ArcaVoiceCore

/// Live transcription for Macs that predate SpeechAnalyzer (macOS 15 and
/// earlier): `SFSpeechRecognizer` fed from the capture stream. On-device when
/// the locale supports it, otherwise Apple's server, whose one-minute cap per
/// request is why the request is rotated every ~50 seconds of audio. Each
/// rotation is one segment window; partials inside a window share an id so
/// the UI animates them in place, exactly as with the newer engine.
public final class LegacyLiveTranscriber: LiveTranscriber, @unchecked Sendable {
    private let vocabulary: [String]
    static let windowSeconds: TimeInterval = 50

    public init(vocabulary: [String] = []) {
        self.vocabulary = vocabulary
    }

    public static func isLocaleSupported(_ locale: Locale) -> Bool {
        SFSpeechRecognizer.supportedLocales().contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    public func transcribe(_ buffers: AsyncStream<CapturedBuffer>, channel: CaptureChannel, locale: Locale)
        -> AsyncThrowingStream<LiveSegment, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer() else {
                        throw TranscribeError.localeNotSupported(locale.identifier)
                    }
                    try await LegacySpeech.ensureAuthorized()
                    let onDevice = recognizer.supportsOnDeviceRecognition
                    var window = RecognitionWindow(recognizer: recognizer, onDevice: onDevice,
                                                   vocabulary: vocabulary, channel: channel,
                                                   baseOffset: 0, continuation: continuation)
                    var fed: TimeInterval = 0

                    for await captured in buffers {
                        if Task.isCancelled { break }
                        let buffer = captured.buffer
                        fed += TimeInterval(buffer.frameLength) / buffer.format.sampleRate
                        if window.isClosed || fed - window.baseOffset >= Self.windowSeconds {
                            window.finish()
                            window = RecognitionWindow(recognizer: recognizer, onDevice: onDevice,
                                                       vocabulary: vocabulary, channel: channel,
                                                       baseOffset: fed, continuation: continuation)
                        }
                        window.append(buffer)
                    }
                    window.finish()
                    await window.waitUntilDone()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One `SFSpeechAudioBufferRecognitionRequest` and its task.
    private final class RecognitionWindow: @unchecked Sendable {
        let request = SFSpeechAudioBufferRecognitionRequest()
        let baseOffset: TimeInterval
        private var task: SFSpeechRecognitionTask?
        private let lock = NSLock()
        private var closed = false
        private var done = false
        private let id = UUID()

        var isClosed: Bool { lock.withLock { closed } }

        init(recognizer: SFSpeechRecognizer, onDevice: Bool, vocabulary: [String], channel: CaptureChannel,
             baseOffset: TimeInterval, continuation: AsyncThrowingStream<LiveSegment, Error>.Continuation) {
            self.baseOffset = baseOffset
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = onDevice
            request.taskHint = .dictation
            if !vocabulary.isEmpty { request.contextualStrings = vocabulary }
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        let (start, end) = LegacySpeech.timeRange(of: result.bestTranscription.segments, offset: baseOffset)
                        continuation.yield(LiveSegment(id: self.id, channel: channel, text: text,
                                                       start: start, end: end, isVolatile: !result.isFinal))
                    }
                }
                if result?.isFinal == true || error != nil {
                    // Either way this request takes no more audio; the feeder
                    // opens a new window. A "no speech" error is just silence.
                    self.lock.withLock { self.closed = true; self.done = true }
                }
            }
        }

        func append(_ buffer: AVAudioPCMBuffer) {
            guard !isClosed else { return }
            request.append(buffer)
        }

        func finish() {
            guard !lock.withLock({ closed }) else { return }
            lock.withLock { closed = true }
            request.endAudio()
        }

        /// Gives the final result up to a few seconds to land after endAudio.
        func waitUntilDone() async {
            for _ in 0..<40 {
                if lock.withLock({ done }) { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            task?.cancel()
        }
    }
}

/// File transcription on `SFSpeechRecognizer` for Macs without SpeechAnalyzer.
/// The file is cut into ~50 s windows (the server path caps a request at one
/// minute; on-device has no cap but the same cut keeps memory flat) and each
/// window is recognized in turn with its time offset added back.
public struct LegacyFileTranscriber: FinalTranscriber {
    private let locale: Locale?
    static let windowSeconds: TimeInterval = 50

    public init(locale: Locale? = nil) {
        self.locale = locale
    }

    public func transcribe(fileURL: URL, channel: CaptureChannel,
                           hints: TranscriptHints) async throws -> Transcript {
        let resolved = Self.resolveLocale(preferred: locale, hints: hints)
        guard let recognizer = SFSpeechRecognizer(locale: resolved) ?? SFSpeechRecognizer() else {
            throw TranscribeError.localeNotSupported(resolved.identifier)
        }
        try await LegacySpeech.ensureAuthorized()
        let onDevice = recognizer.supportsOnDeviceRecognition

        let file = try AVAudioFile(forReading: fileURL)
        let format = file.processingFormat
        let framesPerWindow = AVAudioFrameCount(Self.windowSeconds * format.sampleRate)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arca-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var segments: [Transcript.Segment] = []
        var offset: TimeInterval = 0
        var index = 0
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerWindow) else { break }
            try file.read(into: buffer, frameCount: framesPerWindow)
            guard buffer.frameLength > 0 else { break }
            let chunkURL = tempDir.appendingPathComponent("chunk-\(index).caf")
            let writer = try AVAudioFile(forWriting: chunkURL, settings: format.settings,
                                         commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            try writer.write(from: buffer)
            let words = try await Self.recognize(url: chunkURL, recognizer: recognizer,
                                                 onDevice: onDevice, vocabulary: hints.vocabulary)
            if let words {
                segments += Self.group(words, offset: offset)
            }
            offset += TimeInterval(buffer.frameLength) / format.sampleRate
            index += 1
        }
        return Transcript(channel: channel, segments: segments.sorted { $0.start < $1.start },
                          languageCode: resolved.identifier)
    }

    static func resolveLocale(preferred: Locale?, hints: TranscriptHints) -> Locale {
        let supported = SFSpeechRecognizer.supportedLocales()
        func match(_ candidate: Locale) -> Locale? {
            if let exact = supported.first(where: { $0.identifier(.bcp47) == candidate.identifier(.bcp47) }) { return exact }
            guard let language = candidate.language.languageCode?.identifier else { return nil }
            return supported.first { $0.language.languageCode?.identifier == language }
        }
        for candidate in [preferred, Locale.current].compactMap({ $0 }) {
            if let hit = match(candidate) { return hit }
        }
        for code in hints.languageCodes {
            if let hit = match(Locale(identifier: code)) { return hit }
        }
        return preferred ?? Locale.current
    }

    /// A recognized word with its timing — `SFTranscription` itself isn't Sendable.
    struct Word: Sendable {
        let text: String
        let timestamp: TimeInterval
        let duration: TimeInterval
        let confidence: Float
        init(_ segment: SFTranscriptionSegment) {
            text = segment.substring; timestamp = segment.timestamp
            duration = segment.duration; confidence = segment.confidence
        }
    }

    private static func recognize(url: URL, recognizer: SFSpeechRecognizer, onDevice: Bool,
                                  vocabulary: [String]) async throws -> [Word]? {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = onDevice
        request.taskHint = .dictation
        if !vocabulary.isEmpty { request.contextualStrings = vocabulary }
        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    continuation.resume(returning: result.bestTranscription.segments.map(Word.init))
                } else if let error {
                    finished = true
                    // Silence comes back as an error, not as an empty result.
                    let code = (error as NSError).code
                    if code == 1110 || code == 203 { continuation.resume(returning: nil) }
                    else { continuation.resume(throwing: error) }
                }
            }
        }
    }

    /// Word-level segments become sentence-ish rows: split at pauses or length.
    static func group(_ words: [Word], offset: TimeInterval) -> [Transcript.Segment] {
        var out: [Transcript.Segment] = []
        var text = ""
        var start: TimeInterval = 0
        var end: TimeInterval = 0
        var confidences: [Float] = []
        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            let confidence = confidences.isEmpty ? nil : Double(confidences.reduce(0, +) / Float(confidences.count))
            out.append(Transcript.Segment(text: trimmed, start: offset + start, end: offset + end,
                                          confidence: confidence, speakerLabel: nil))
            text = ""; confidences = []
        }
        for word in words {
            let wordStart = word.timestamp, wordEnd = word.timestamp + word.duration
            if !text.isEmpty && (wordStart - end > 0.8 || wordEnd - start > 12) { flush() }
            if text.isEmpty { start = wordStart }
            text += (text.isEmpty ? "" : " ") + word.text
            end = wordEnd
            confidences.append(word.confidence)
        }
        flush()
        return out
    }
}

enum LegacySpeech {
    static func ensureAuthorized() async throws {
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            let current = SFSpeechRecognizer.authorizationStatus()
            if current == .notDetermined {
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            } else {
                continuation.resume(returning: current)
            }
        }
        guard status == .authorized else { throw TranscribeError.speechNotAuthorized }
    }

    static func timeRange(of segments: [SFTranscriptionSegment], offset: TimeInterval) -> (TimeInterval, TimeInterval) {
        guard let first = segments.first, let last = segments.last else { return (offset, offset) }
        return (offset + first.timestamp, offset + last.timestamp + last.duration)
    }
}
