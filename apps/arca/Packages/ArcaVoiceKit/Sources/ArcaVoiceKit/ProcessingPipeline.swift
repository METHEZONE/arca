import Foundation
import ArcaVoiceCore
import Capture
import Transcribe
import Diarize
import Intelligence

/// The post-recording quality pass: per-channel high-quality transcription
/// (with diarization on the system channel), channel merge, then LLM notes.
public struct ProcessingPipeline: Sendable {
    /// Where the transcript in an `Output` actually came from.
    public enum TranscriptSource: String, Sendable {
        /// The final pass produced it — cloud, or the on-device file fallback.
        case finalPass
        /// Nothing could transcribe the audio, so the live on-device segments
        /// already sitting in the store were promoted instead. The caller must
        /// not overwrite its stored segments with these: they *are* them.
        case liveSegments
    }

    public struct Output: Sendable {
        public let transcript: AttributedTranscript
        public let notes: MeetingNotes?
        /// Channels that threw while the pass still produced a usable transcript.
        /// Non-empty means the meeting is only partly transcribed — the caller
        /// surfaces this instead of presenting a half transcript as complete.
        public let channelErrors: [String]
        public let transcriptSource: TranscriptSource

        public init(transcript: AttributedTranscript, notes: MeetingNotes?,
                    channelErrors: [String] = [],
                    transcriptSource: TranscriptSource = .finalPass) {
            self.transcript = transcript
            self.notes = notes
            self.channelErrors = channelErrors
            self.transcriptSource = transcriptSource
        }
    }

    private let finalTranscriber: any FinalTranscriber
    private let summarizer: (any Summarizer)?

    public init(finalTranscriber: any FinalTranscriber, summarizer: (any Summarizer)?) {
        self.finalTranscriber = finalTranscriber
        self.summarizer = summarizer
    }

    /// - Parameter liveFallback: the transcript already reconstructed from the
    ///   session's stored live segments, if it has any. Used only when nothing
    ///   could transcribe the audio — a cloud outage then costs the user note
    ///   quality, not the whole meeting.
    public func process(
        files: [CaptureChannel: URL],
        ownerName: String,
        hints: TranscriptHints = TranscriptHints(),
        userNotes: String? = nil,
        liveFallback: AttributedTranscript? = nil
    ) async throws -> Output {
        // One dead channel (empty mic file, corrupt tap) must not sink the
        // whole pass — transcribe per channel, keep what succeeds, and only
        // fail if EVERY channel failed.
        var channelErrors: [String] = []
        let channelTurns = await withTaskGroup(
            of: Result<(CaptureChannel, [SpeakerTurn]), Error>.self
        ) { group in
            for (channel, url) in files {
                let transcriber = finalTranscriber
                group.addTask {
                    // A header-only file means the channel never captured.
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                    guard size > 4096 else {
                        return .success((channel, []))
                    }
                    do {
                        let transcript = try await transcriber.transcribe(
                            fileURL: url, channel: channel, hints: hints)
                        return .success((channel, Self.turns(from: transcript, channel: channel)))
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var result: [CaptureChannel: [SpeakerTurn]] = [:]
            for await outcome in group {
                switch outcome {
                case .success(let (channel, turns)): result[channel] = turns
                case .failure(let error): channelErrors.append(error.localizedDescription)
                }
            }
            return result
        }
        // A channel that FAILED is not the same as one that was simply silent.
        // Keying on `channelTurns.isEmpty` conflated them: a dead-quiet system
        // tap returned `.success((.systemAudio, []))`, which made the dictionary
        // non-empty and swallowed a genuine mic failure — the caller then wiped
        // the live transcript and stored nothing, with no error to retry from.
        let usableTurns = channelTurns.values.contains { !$0.isEmpty }

        // Failing shut here is what used to leave a session with no transcript
        // AND no notes: the throw happened before summarization, so a cloud
        // outage erased the meeting from the user's point of view even though
        // the live pass had already written text into the store. If there is
        // any transcript to work with — even the degraded live one — the pass
        // continues and summarizes it.
        var source = TranscriptSource.finalPass
        var merged: AttributedTranscript
        if usableTurns {
            merged = TranscriptMerger.merge(ownerName: ownerName, channelTurns: channelTurns)
        } else if let liveFallback, !liveFallback.turns.isEmpty {
            merged = liveFallback
            source = .liveSegments
        } else if let firstError = channelErrors.first {
            throw PipelineError.allChannelsFailed(firstError)
        } else {
            // No errors and no speech: a genuinely silent recording.
            merged = TranscriptMerger.merge(ownerName: ownerName, channelTurns: channelTurns)
        }

        var notes: MeetingNotes?
        if let summarizer, !merged.turns.isEmpty {
            let style: NoteStyle = (userNotes?.isEmpty == false) ? .enhancedNotes : .meetingSummary
            notes = try await summarizer.summarize(merged, userNotes: userNotes, style: style)
        }
        return Output(transcript: merged, notes: notes,
                      channelErrors: channelErrors, transcriptSource: source)
    }

    /// Groups consecutive same-speaker segments into readable turns.
    static func turns(from transcript: Transcript, channel: CaptureChannel) -> [SpeakerTurn] {
        var turns: [SpeakerTurn] = []
        for segment in transcript.segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let label = segment.speakerLabel ?? "S1"
            let key = "\(channel.rawValue):\(label)"
            if var last = turns.last, last.speakerKey == key, segment.start - last.end < 2.0 {
                last.text += " " + text
                last.end = segment.end
                turns[turns.count - 1] = last
            } else {
                turns.append(SpeakerTurn(
                    speakerKey: key, text: text,
                    start: segment.start, end: segment.end, channel: channel))
            }
        }
        return turns
    }
}

public enum PipelineError: Error, LocalizedError {
    case allChannelsFailed(String)

    public var errorDescription: String? {
        switch self {
        case .allChannelsFailed(let detail): return "Transcription failed on every channel: \(detail)"
        }
    }
}
