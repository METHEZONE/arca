import Foundation
import SwiftData
import ArcaVoiceCore

public enum SessionState: String, Codable, Sendable {
    case recording
    case processing
    case ready
    case failed
}

public enum SessionSource: String, Codable, Sendable {
    case macMeeting
    case voiceMemo
    case watchMemo
    case screenshot
    case shared
    case imported
}

@Model
public final class RecordingSession {
    public var title: String
    public var createdAt: Date
    public var stateRaw: String
    public var sourceRaw: String
    public var duration: TimeInterval
    /// Folder name under the app's sessions directory holding this session's audio.
    public var directoryName: String
    public var processingError: String?
    /// Last local mutation — relay merge is last-writer-wins.
    public var updatedAt: Date = Date.now

    @Relationship(deleteRule: .cascade) public var audioAssets: [AudioAsset]
    @Relationship(deleteRule: .cascade) public var segments: [StoredSegment]
    @Relationship(deleteRule: .cascade) public var note: SessionNote?

    public var state: SessionState {
        get { SessionState(rawValue: stateRaw) ?? .failed }
        set { stateRaw = newValue.rawValue }
    }

    public var source: SessionSource {
        get { SessionSource(rawValue: sourceRaw) ?? .voiceMemo }
        set { sourceRaw = newValue.rawValue }
    }

    public init(title: String, source: SessionSource, directoryName: String = UUID().uuidString, createdAt: Date = .now) {
        self.title = title
        self.createdAt = createdAt
        self.stateRaw = SessionState.recording.rawValue
        self.sourceRaw = source.rawValue
        self.duration = 0
        self.directoryName = directoryName
        self.processingError = nil
        self.audioAssets = []
        self.segments = []
        self.note = nil
        self.updatedAt = createdAt
    }

    /// Mark the record as locally mutated (call after any meaningful change).
    public func touch() { updatedAt = .now }
}

@Model
public final class AudioAsset {
    public var channelRaw: String
    /// Path relative to the app's audio directory; audio stays local (too big for CloudKit).
    public var relativePath: String
    public var duration: TimeInterval

    public var channel: CaptureChannel {
        get { CaptureChannel(rawValue: channelRaw) ?? .mixed }
        set { channelRaw = newValue.rawValue }
    }

    public init(channel: CaptureChannel, relativePath: String, duration: TimeInterval) {
        self.channelRaw = channel.rawValue
        self.relativePath = relativePath
        self.duration = duration
    }
}

@Model
public final class StoredSegment {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var channelRaw: String
    public var speakerKey: String?
    /// false while only the live pass has run; true once the final pass replaced it.
    public var isFinal: Bool

    @Relationship public var speaker: SpeakerRecord?

    public init(text: String, start: TimeInterval, end: TimeInterval,
                channel: CaptureChannel, speakerKey: String? = nil, isFinal: Bool = false) {
        self.text = text
        self.start = start
        self.end = end
        self.channelRaw = channel.rawValue
        self.speakerKey = speakerKey
        self.isFinal = isFinal
    }
}

@Model
public final class SpeakerRecord {
    public var name: String
    public var colorHex: String
    /// Serialized [SpeakerEmbedding] — the voice-print that lets ARCA recognize
    /// this person in future meetings.
    public var embeddingData: Data?

    public init(name: String, colorHex: String, embeddingData: Data? = nil) {
        self.name = name
        self.colorHex = colorHex
        self.embeddingData = embeddingData
    }
}

@Model
public final class SessionNote {
    /// The user's rough notes typed during recording, with timestamp anchors.
    public var roughMarkdown: String
    public var enhancedMarkdown: String?
    public var summaryMarkdown: String?
    public var decisionsJSON: Data?
    public var actionItemsJSON: Data?

    public init(roughMarkdown: String = "") {
        self.roughMarkdown = roughMarkdown
    }
}
