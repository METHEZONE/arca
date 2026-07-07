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
        return AttributedTranscript(turns: turns, speakerNames: names)
    }
}
