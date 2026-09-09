import Foundation
import ArcaVoiceCore

/// Tries the cloud pass first, then an on-device pass over the same file.
///
/// Mirrors `FallbackSummarizer`. Until this existed, `OpenAIDiarizedTranscriber`
/// was the only `FinalTranscriber` in the app: a dead key, a rate limit, an
/// outage, or simply no network left the session with no transcript — and because
/// the pipeline threw before summarization, no notes either.
///
/// An empty primary result counts as a failure too. Whisper returning zero
/// segments on audio that plainly contains speech is the same outage from the
/// user's side as an HTTP 500, and it was already the most common way a session
/// ended up with nothing.
public struct FallbackTranscriber: FinalTranscriber {
    private let primary: any FinalTranscriber
    private let fallback: any FinalTranscriber
    private let log: (@Sendable (String) -> Void)?

    public init(primary: any FinalTranscriber,
                fallback: any FinalTranscriber,
                log: (@Sendable (String) -> Void)? = nil) {
        self.primary = primary
        self.fallback = fallback
        self.log = log
    }

    public func transcribe(fileURL: URL, channel: CaptureChannel,
                           hints: TranscriptHints) async throws -> Transcript {
        var primaryFailure: Error?
        do {
            let transcript = try await primary.transcribe(
                fileURL: fileURL, channel: channel, hints: hints)
            if !transcript.segments.isEmpty { return transcript }
            log?("transcribe: primary returned no speech on \(channel.rawValue), trying on-device")
        } catch {
            primaryFailure = error
            log?("transcribe: primary failed on \(channel.rawValue) — \(error.localizedDescription), trying on-device")
        }

        do {
            let transcript = try await fallback.transcribe(
                fileURL: fileURL, channel: channel, hints: hints)
            log?("transcribe: on-device fallback produced \(transcript.segments.count) segment(s) on \(channel.rawValue)")
            return transcript
        } catch let fallbackError {
            // The primary error is the actionable one for the user (dead key,
            // rate limit, offline); the fallback's is a footnote on top of it.
            throw primaryFailure ?? fallbackError
        }
    }
}
