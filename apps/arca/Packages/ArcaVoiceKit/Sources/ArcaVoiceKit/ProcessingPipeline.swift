import Foundation
import ArcaVoiceCore
import Capture
import Transcribe
import Diarize
import Intelligence

/// The post-recording quality pass: per-channel high-quality transcription
/// (with diarization on the system channel), channel merge, then LLM notes.
public struct ProcessingPipeline: Sendable {
    public struct Output: Sendable {
        public let transcript: AttributedTranscript
        public let notes: MeetingNotes?
        /// Set when the pass finished cleanly but produced no turns. The caller
        /// needs this to tell "nothing was said" from "the transcript is gone",
        /// because those two demand opposite handling: one is a fact about the
        /// recording, the other must never overwrite what's already stored.
        public let emptyReason: EmptyReason?

        public init(transcript: AttributedTranscript,
                    notes: MeetingNotes?,
                    emptyReason: EmptyReason? = nil) {
            self.transcript = transcript
            self.notes = notes
            self.emptyReason = emptyReason
        }
    }

    /// Why a successful pass came back with nothing.
    public enum EmptyReason: Sendable, Equatable {
        /// Every file was too small to hold audio — the capture itself is empty.
        case noAudioCaptured
        /// Transcription ran over real audio and found no speech.
        case noSpeechFound
    }

    /// One channel's result, so the merge step can tell a silent channel from a
    /// broken one instead of collapsing both into an empty array.
    private enum ChannelOutcome: Sendable {
        case turns(CaptureChannel, [SpeakerTurn])
        case noAudio(CaptureChannel)
        case failed(String)
    }

    private let finalTranscriber: any FinalTranscriber
    private let summarizer: (any Summarizer)?

    public init(finalTranscriber: any FinalTranscriber, summarizer: (any Summarizer)?) {
        self.finalTranscriber = finalTranscriber
        self.summarizer = summarizer
    }

    public func process(
        files: [CaptureChannel: URL],
        ownerName: String,
        hints: TranscriptHints = TranscriptHints(),
        userNotes: String? = nil
    ) async throws -> Output {
        // One dead channel (empty mic file, corrupt tap) must not sink the
        // whole pass — transcribe per channel, keep what succeeds, and only
        // fail if EVERY channel failed.
        let outcomes = await withTaskGroup(of: ChannelOutcome.self) { group in
            for (channel, url) in files {
                let transcriber = finalTranscriber
                group.addTask {
                    // A header-only file means the channel never captured.
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                    guard size > 4096 else { return .noAudio(channel) }
                    do {
                        let transcript = try await transcriber.transcribe(
                            fileURL: url, channel: channel, hints: hints)
                        return .turns(channel, Self.turns(from: transcript, channel: channel))
                    } catch {
                        return .failed(error.localizedDescription)
                    }
                }
            }
            var all: [ChannelOutcome] = []
            for await outcome in group { all.append(outcome) }
            return all
        }

        var channelTurns: [CaptureChannel: [SpeakerTurn]] = [:]
        var channelErrors: [String] = []
        var transcribedChannels = 0
        for outcome in outcomes {
            switch outcome {
            case .turns(let channel, let turns):
                transcribedChannels += 1
                channelTurns[channel] = turns
            case .noAudio:
                break
            case .failed(let message):
                channelErrors.append(message)
            }
        }

        // Test for produced *turns*, not for dictionary entries. A channel that
        // transcribed to nothing still occupies a key, so checking the dictionary
        // made a total failure look like a success with an empty transcript —
        // which is how a recording's text got thrown away downstream.
        let producedTurns = channelTurns.values.contains { !$0.isEmpty }
        if !producedTurns, let firstError = channelErrors.first {
            throw PipelineError.allChannelsFailed(firstError)
        }

        let merged = TranscriptMerger.merge(ownerName: ownerName, channelTurns: channelTurns)

        guard producedTurns else {
            return Output(transcript: merged, notes: nil,
                          emptyReason: transcribedChannels == 0 ? .noAudioCaptured : .noSpeechFound)
        }

        var notes: MeetingNotes?
        if let summarizer, !merged.turns.isEmpty {
            let style: NoteStyle = (userNotes?.isEmpty == false) ? .enhancedNotes : .meetingSummary
            notes = try await summarizer.summarize(merged, userNotes: userNotes, style: style)
        }
        return Output(transcript: merged, notes: notes)
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
