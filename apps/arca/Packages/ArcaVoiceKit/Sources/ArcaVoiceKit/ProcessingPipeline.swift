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
        let channelTurns = try await withThrowingTaskGroup(
            of: (CaptureChannel, [SpeakerTurn]).self
        ) { group in
            for (channel, url) in files {
                let transcriber = finalTranscriber
                group.addTask {
                    let transcript = try await transcriber.transcribe(
                        fileURL: url, channel: channel, hints: hints)
                    return (channel, Self.turns(from: transcript, channel: channel))
                }
            }
            var result: [CaptureChannel: [SpeakerTurn]] = [:]
            for try await (channel, turns) in group {
                result[channel] = turns
            }
            return result
        }

        let merged = TranscriptMerger.merge(ownerName: ownerName, channelTurns: channelTurns)

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
