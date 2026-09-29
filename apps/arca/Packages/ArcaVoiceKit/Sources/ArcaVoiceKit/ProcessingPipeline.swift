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
        /// Set when the pass finished cleanly but produced no turns. The caller
        /// needs this to tell "nothing was said" from "the transcript is gone",
        /// because those two demand opposite handling: one is a fact about the
        /// recording, the other must never overwrite what's already stored.
        public let emptyReason: EmptyReason?
        /// Channels that threw while the pass still produced a usable transcript.
        /// Non-empty means the meeting is only partly transcribed — the caller
        /// surfaces this instead of presenting a half transcript as complete.
        public let channelErrors: [String]
        public let transcriptSource: TranscriptSource
        /// True when `speakerAttributor` named the speakers. For a
        /// `.liveSegments` transcript the turns are then one per stored
        /// segment, in `SessionResummarizer.orderedSegments` order, so the
        /// caller can write the names back onto the rows it already has.
        public let speakersAttributed: Bool
        /// Why `notes` is nil when a summarizer was configured. The transcript
        /// is complete and must be kept; only the notes are owed.
        public let summaryError: String?
        /// Why speakers stayed unnamed, for the trace log.
        public let attributionError: String?

        public init(transcript: AttributedTranscript,
                    notes: MeetingNotes?,
                    emptyReason: EmptyReason? = nil,
                    channelErrors: [String] = [],
                    transcriptSource: TranscriptSource = .finalPass,
                    speakersAttributed: Bool = false,
                    summaryError: String? = nil,
                    attributionError: String? = nil) {
            self.transcript = transcript
            self.notes = notes
            self.emptyReason = emptyReason
            self.channelErrors = channelErrors
            self.transcriptSource = transcriptSource
            self.speakersAttributed = speakersAttributed
            self.summaryError = summaryError
            self.attributionError = attributionError
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
    private let speakerAttributor: (any SpeakerAttributor)?

    public init(finalTranscriber: any FinalTranscriber, summarizer: (any Summarizer)?,
                speakerAttributor: (any SpeakerAttributor)? = nil) {
        self.finalTranscriber = finalTranscriber
        self.summarizer = summarizer
        self.speakerAttributor = speakerAttributor
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
        // Attribution works line by line, so segments stay separate until it
        // has run — grouping first would glue two people's lines together.
        let groupSegments = speakerAttributor == nil
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
                        return .turns(channel, Self.turns(from: transcript, channel: channel,
                                                          grouped: groupSegments))
                    } catch {
                        return .failed(error.localizedDescription)
                    }
                }
            }
            var all: [ChannelOutcome] = []
            for await outcome in group { all.append(outcome) }
            return all
        }

        // A channel that FAILED is not the same as one that was simply silent,
        // and neither is the same as one that never captured. Collapsing them
        // swallowed a genuine mic failure behind a dead-quiet system tap.
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

        // Failing shut here is what used to leave a session with no transcript
        // AND no notes: the throw happened before summarization, so a cloud
        // outage erased the meeting from the user's point of view even though
        // the live pass had already written text into the store. If there is
        // any transcript to work with — even the degraded live one — the pass
        // continues and summarizes it.
        var source = TranscriptSource.finalPass
        var merged: AttributedTranscript
        if producedTurns {
            merged = TranscriptMerger.merge(ownerName: ownerName, channelTurns: channelTurns)
        } else if let liveFallback, !liveFallback.turns.isEmpty {
            merged = liveFallback
            source = .liveSegments
        } else if let firstError = channelErrors.first {
            throw PipelineError.allChannelsFailed(firstError)
        } else {
            // Nothing was said and there is no live transcript to fall back on.
            // Report *why* rather than handing back a blank success, so the
            // caller can keep whatever it already stored.
            return Output(transcript: TranscriptMerger.merge(ownerName: ownerName,
                                                             channelTurns: channelTurns),
                          notes: nil,
                          emptyReason: transcribedChannels == 0 ? .noAudioCaptured : .noSpeechFound,
                          channelErrors: channelErrors)
        }

        var attributed = false
        var attributionError: String?
        if let speakerAttributor, Self.needsAttribution(merged) {
            do {
                let names = try await speakerAttributor.speakers(
                    for: merged, context: SpeakerContext(ownerName: ownerName,
                                                         participants: hints.vocabulary))
                if names.count == merged.turns.count {
                    for index in merged.turns.indices { merged.turns[index].speakerKey = names[index] }
                    merged.speakerNames = [:]
                    attributed = true
                } else {
                    attributionError = "\(names.count) names for \(merged.turns.count) lines"
                }
            } catch {
                // Not worth losing the meeting over: the transcript stands as
                // it is, filed under the channel labels it already had.
                attributionError = "\(error)"
            }
        }
        if source == .finalPass && !groupSegments {
            merged.turns = Self.grouped(merged.turns)
        }

        // A summary that fails must not take the transcript down with it: the
        // words are what was paid for and what the user came for. It used to
        // throw from here, the finished cloud transcript was dropped, and the
        // retry paid to transcribe the whole meeting again.
        var notes: MeetingNotes?
        var summaryError: String?
        if let summarizer, !merged.turns.isEmpty {
            let style: NoteStyle = (userNotes?.isEmpty == false) ? .enhancedNotes : .meetingSummary
            do {
                notes = try await summarizer.summarize(merged, userNotes: userNotes, style: style)
            } catch {
                summaryError = error.localizedDescription
            }
        }
        return Output(transcript: merged, notes: notes,
                      channelErrors: channelErrors, transcriptSource: source,
                      speakersAttributed: attributed, summaryError: summaryError,
                      attributionError: attributionError)
    }

    /// Only transcripts still filed under channel labels: a live transcript
    /// that was already attributed (its stored rows carry names) is left alone.
    static func needsAttribution(_ transcript: AttributedTranscript) -> Bool {
        guard transcript.turns.count >= 2 else { return false }
        let channelLabels: Set<String> = ["owner", "Me", "Other"]
        return transcript.turns.allSatisfy {
            channelLabels.contains($0.speakerKey) || $0.speakerKey.contains(":")
        }
    }

    /// One turn per non-empty segment, or consecutive same-speaker segments
    /// joined into readable turns when `grouped`.
    static func turns(from transcript: Transcript, channel: CaptureChannel,
                      grouped: Bool = true) -> [SpeakerTurn] {
        let turns = transcript.segments.flatMap { segment -> [SpeakerTurn] in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            let key = "\(channel.rawValue):\(segment.speakerLabel ?? "S1")"
            // Whisper sometimes returns half a minute of back-and-forth as one
            // segment, and attribution can only name whole lines — so for it,
            // lines are sentences.
            let pieces = grouped ? [(text, segment.start, segment.end)]
                : sentences(text, start: segment.start, end: segment.end)
            return pieces.map { SpeakerTurn(speakerKey: key, text: $0.0, start: $0.1, end: $0.2, channel: channel) }
        }
        return grouped ? Self.grouped(turns) : turns
    }

    /// Splits at sentence ends, sharing out the time by length.
    static func sentences(_ text: String, start: TimeInterval, end: TimeInterval)
        -> [(String, TimeInterval, TimeInterval)] {
        var parts: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            current.append(character)
            let atBoundary = ".?!。？！".contains(character)
                && (index + 1 == characters.count || characters[index + 1].isWhitespace)
            if atBoundary {
                let piece = current.trimmingCharacters(in: .whitespaces)
                if !piece.isEmpty { parts.append(piece) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { parts.append(tail) }
        guard parts.count > 1 else { return [(text, start, end)] }
        let total = Double(parts.reduce(0) { $0 + $1.count })
        var cursor = start
        return parts.map { part in
            let length = (end - start) * Double(part.count) / total
            defer { cursor += length }
            return (part, cursor, cursor + length)
        }
    }

    /// Joins consecutive turns by the same speaker on the same channel that are
    /// less than two seconds apart.
    static func grouped(_ turns: [SpeakerTurn]) -> [SpeakerTurn] {
        var result: [SpeakerTurn] = []
        for turn in turns {
            if var last = result.last, last.speakerKey == turn.speakerKey,
               last.channel == turn.channel, turn.start - last.end < 2.0 {
                last.text += " " + turn.text
                last.end = max(last.end, turn.end)
                result[result.count - 1] = last
            } else {
                result.append(turn)
            }
        }
        return result
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
