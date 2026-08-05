import Foundation
import ArcaVoiceCore

/// Splits one channel's transcript into speaker turns. Speaker count is unbounded.
public protocol Diarizer: Sendable {
    func diarize(fileURL: URL, transcript: Transcript) async throws -> [SpeakerTurn]
}

/// Voice-print extraction and cross-meeting matching.
public protocol SpeakerIdentifier: Sendable {
    func embed(turns: [SpeakerTurn], audio: URL) async throws -> [String: SpeakerEmbedding]
    func match(_ embedding: SpeakerEmbedding, against speakers: [KnownSpeaker]) -> SpeakerMatch?
}

/// Merges per-channel speaker turns into one time-ordered attributed transcript.
/// The mic channel is always the session owner; system-audio turns keep their
/// diarization labels until voice-print matching or the user names them.
public enum TranscriptMerger {
    public static func merge(ownerName: String, channelTurns: [CaptureChannel: [SpeakerTurn]]) -> AttributedTranscript {
        var turns: [SpeakerTurn] = []
        var names: [String: String] = [:]
        for (channel, channelTurnList) in channelTurns {
            if channel == .microphone {
                names["owner"] = ownerName
                turns.append(contentsOf: channelTurnList.map {
                    var turn = $0
                    turn.speakerKey = "owner"
                    return turn
                })
            } else {
                turns.append(contentsOf: channelTurnList)
            }
        }
        turns.sort { $0.start < $1.start }

        // Give the remote keys a readable name. Without this the raw key is
        // what everything downstream falls back to — and on the on-device
        // engine, which emits no diarization at all, that key is the literal
        // string "systemAudio:S1". It was being shown in the transcript and
        // handed to the summarizer as a person's name.
        let remoteKeys = turns
            .filter { $0.channel != .microphone }
            .map(\.speakerKey)
        var seen: [String] = []
        for key in remoteKeys where !seen.contains(key) { seen.append(key) }
        for (index, key) in seen.enumerated() where names[key] == nil {
            // One remote voice needs no number; several are worth telling apart
            // even before anyone puts real names to them.
            names[key] = seen.count == 1 ? "Other" : "Speaker \(index + 1)"
        }

        return AttributedTranscript(turns: turns, speakerNames: names)
    }
}
