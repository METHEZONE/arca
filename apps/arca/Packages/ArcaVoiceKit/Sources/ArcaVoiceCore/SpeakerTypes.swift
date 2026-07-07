import Foundation

/// One speaker-attributed span after diarization + channel merge.
public struct SpeakerTurn: Sendable {
    public var speakerKey: String
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var channel: CaptureChannel

    public init(speakerKey: String, text: String, start: TimeInterval,
                end: TimeInterval, channel: CaptureChannel) {
        self.speakerKey = speakerKey
        self.text = text
        self.start = start
        self.end = end
        self.channel = channel
    }
}

/// A voice-print vector for cross-meeting speaker identification.
public struct SpeakerEmbedding: Sendable, Codable {
    public var vector: [Float]
    public var sourceDuration: TimeInterval

    public init(vector: [Float], sourceDuration: TimeInterval) {
        self.vector = vector
        self.sourceDuration = sourceDuration
    }
}

public struct KnownSpeaker: Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var embeddings: [SpeakerEmbedding]

    public init(id: UUID = UUID(), name: String, embeddings: [SpeakerEmbedding] = []) {
        self.id = id
        self.name = name
        self.embeddings = embeddings
    }
}

public struct SpeakerMatch: Sendable {
    public var speakerID: UUID
    public var similarity: Double

    public init(speakerID: UUID, similarity: Double) {
        self.speakerID = speakerID
        self.similarity = similarity
    }
}

/// Final merged product: every turn attributed, ordered by time.
public struct AttributedTranscript: Sendable {
    public var turns: [SpeakerTurn]
    /// speakerKey → display name (resolved via voice-print or user edit).
    public var speakerNames: [String: String]

    public init(turns: [SpeakerTurn], speakerNames: [String: String] = [:]) {
        self.turns = turns
        self.speakerNames = speakerNames
    }
}
