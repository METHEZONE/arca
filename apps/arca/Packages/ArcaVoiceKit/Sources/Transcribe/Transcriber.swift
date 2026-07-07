import Foundation
import ArcaVoiceCore

/// Streaming on-device transcription shown while recording.
/// One instance per channel — feed it that channel's buffers only.
public protocol LiveTranscriber: Sendable {
    func transcribe(_ buffers: AsyncStream<CapturedBuffer>, channel: CaptureChannel, locale: Locale)
        -> AsyncThrowingStream<LiveSegment, Error>
}

/// High-quality batch pass run after recording ends.
public protocol FinalTranscriber: Sendable {
    func transcribe(fileURL: URL, channel: CaptureChannel, hints: TranscriptHints) async throws -> Transcript
}
