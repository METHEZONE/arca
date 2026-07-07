import Foundation
import SwiftData
import ArcaVoiceCore

/// Wire format for relaying a session (transcript + notes) between devices.
/// Audio stays on the device that recorded it — the transcript is the durable
/// artifact. Keyed by `RecordingSession.directoryName` (a UUID string).
public struct SessionWire: Codable, Sendable {
    public struct SegmentWire: Codable, Sendable {
        public var text: String
        public var start: TimeInterval
        public var end: TimeInterval
        public var channelRaw: String
        public var speakerKey: String?
        public var speakerName: String?
    }

    public var uid: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var stateRaw: String
    public var sourceRaw: String
    public var duration: TimeInterval
    public var segments: [SegmentWire]
    public var roughMarkdown: String?
    public var enhancedMarkdown: String?
    public var summaryMarkdown: String?
    public var decisionsJSON: Data?
    public var actionItemsJSON: Data?

    public init(_ session: RecordingSession) {
        uid = session.directoryName
        title = session.title
        createdAt = session.createdAt
        updatedAt = session.updatedAt
        stateRaw = session.stateRaw
        sourceRaw = session.sourceRaw
        duration = session.duration
        segments = session.segments
            .filter(\.isFinal)
            .sorted { $0.start < $1.start }
            .map {
                SegmentWire(text: $0.text, start: $0.start, end: $0.end,
                            channelRaw: $0.channelRaw, speakerKey: $0.speakerKey,
                            speakerName: $0.speaker?.name)
            }
        roughMarkdown = session.note?.roughMarkdown
        enhancedMarkdown = session.note?.enhancedMarkdown
        summaryMarkdown = session.note?.summaryMarkdown
        decisionsJSON = session.note?.decisionsJSON
        actionItemsJSON = session.note?.actionItemsJSON
    }

    /// Applies wire content onto a local record (no audio assets; segments are
    /// replaced wholesale — remote is authoritative for a newer session).
    public func apply(to session: RecordingSession, context: ModelContext) {
        session.title = title
        session.createdAt = createdAt
        session.updatedAt = updatedAt
        session.stateRaw = stateRaw
        session.sourceRaw = sourceRaw
        session.duration = duration

        for old in session.segments { context.delete(old) }
        session.segments = segments.map {
            StoredSegment(text: $0.text, start: $0.start, end: $0.end,
                          channel: CaptureChannel(rawValue: $0.channelRaw) ?? .microphone,
                          speakerKey: $0.speakerKey, isFinal: true)
        }

        let note = session.note ?? SessionNote()
        note.roughMarkdown = roughMarkdown ?? note.roughMarkdown
        note.enhancedMarkdown = enhancedMarkdown ?? note.enhancedMarkdown
        note.summaryMarkdown = summaryMarkdown ?? note.summaryMarkdown
        note.decisionsJSON = decisionsJSON ?? note.decisionsJSON
        note.actionItemsJSON = actionItemsJSON ?? note.actionItemsJSON
        session.note = note
    }
}
