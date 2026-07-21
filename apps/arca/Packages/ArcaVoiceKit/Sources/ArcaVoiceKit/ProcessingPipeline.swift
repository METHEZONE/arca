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
        if channelTurns.isEmpty, let firstError = channelErrors.first {
            throw PipelineError.allChannelsFailed(firstError)
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

public enum PipelineError: Error, LocalizedError {
    case allChannelsFailed(String)

    public var errorDescription: String? {
        switch self {
        case .allChannelsFailed(let detail): return "Transcription failed on every channel: \(detail)"
        }
    }
}
