import AVFoundation
import Foundation
import ArcaVoiceCore

/// Final-pass transcriber that runs Apple's on-device recognizer over an
/// already-saved audio file.
///
/// The same engine as the live pass — `AppleLiveTranscriber`, driven from disk
/// instead of a microphone — which is what makes it usable for recordings that
/// were never transcribed live at all: a Watch memo, an imported file, a session
/// recovered after the app was killed. It produces no diarization and a weaker
/// model than the cloud pass, so it is strictly a fallback. A degraded transcript
/// is worth having; the alternative on a cloud outage was nothing at all.
///
/// Reading a finished file is not the same problem as consuming a microphone: the
/// live path can afford to drop buffers when the analyzer lags, this one cannot,
/// so the reader waits for the analyzer instead of throwing audio away.
public struct AppleFileTranscriber: FinalTranscriber {
    /// Frames per read — a quarter second or so of audio at typical rates.
    private static let framesPerRead: AVAudioFrameCount = 12_000
    /// How many buffers may sit unconsumed ahead of the analyzer. Bounds peak
    /// memory at a few megabytes regardless of how long the meeting was.
    private static let queueDepth = 48

    private let locale: Locale
    private let live: any LiveTranscriber

    public init(locale: Locale, live: any LiveTranscriber = AppleLiveTranscriber()) {
        self.locale = locale
        self.live = live
    }

    public func transcribe(fileURL: URL, channel: CaptureChannel,
                           hints: TranscriptHints) async throws -> Transcript {
        // Probed first so a truncated file (a kill leaves an .m4a whose moov box
        // was never written) fails with a real message instead of quietly
        // yielding an empty transcript.
        try Self.probe(fileURL)

        let (stream, continuation) = AsyncStream<CapturedBuffer>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.queueDepth))

        // The file handle is opened and used entirely inside this task — an
        // AVAudioFile must not cross an isolation boundary.
        let reader = Task.detached(priority: .utility) {
            defer { continuation.finish() }
            guard let file = try? AVAudioFile(forReading: fileURL) else { return }
            let format = file.processingFormat
            var position: AVAudioFramePosition = 0
            while position < file.length, !Task.isCancelled {
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: Self.framesPerRead) else { return }
                do {
                    try file.read(into: buffer)
                } catch {
                    return
                }
                guard buffer.frameLength > 0 else { return }
                let captured = CapturedBuffer(
                    channel: channel, buffer: buffer,
                    elapsed: Double(position) / format.sampleRate)
                position += AVAudioFramePosition(buffer.frameLength)
                // `.bufferingOldest` reports the dropped yield instead of
                // silently discarding it, which is what lets us back off and
                // wait for the analyzer rather than lose that audio.
                var handedOff = false
                while !handedOff {
                    if Task.isCancelled { return }
                    switch continuation.yield(captured) {
                    case .enqueued:
                        handedOff = true
                    case .dropped:
                        try? await Task.sleep(for: .milliseconds(40))
                    case .terminated:
                        return
                    @unknown default:
                        return
                    }
                }
            }
        }
        defer { reader.cancel() }

        var segments: [Transcript.Segment] = []
        for try await segment in live.transcribe(stream, channel: channel, locale: locale) {
            guard !segment.isVolatile else { continue }
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            segments.append(Transcript.Segment(
                text: text, start: segment.start, end: segment.end))
        }
        guard !segments.isEmpty else { throw AppleFileTranscribeError.noSpeechRecognized }
        return Transcript(channel: channel, segments: segments,
                          languageCode: locale.language.languageCode?.identifier)
    }

    private static func probe(_ url: URL) throws {
        guard let file = try? AVAudioFile(forReading: url) else {
            throw AppleFileTranscribeError.unreadableAudio(url.lastPathComponent)
        }
        guard file.processingFormat.sampleRate > 0, file.length > 0 else {
            throw AppleFileTranscribeError.unreadableAudio(url.lastPathComponent)
        }
    }
}

public enum AppleFileTranscribeError: Error, LocalizedError {
    case unreadableAudio(String)
    case noSpeechRecognized

    public var errorDescription: String? {
        switch self {
        case .unreadableAudio(let name):
            return "On-device transcription could not read \(name) — the recording may be truncated."
        case .noSpeechRecognized:
            return "On-device transcription found no speech in the recording."
        }
    }
}
