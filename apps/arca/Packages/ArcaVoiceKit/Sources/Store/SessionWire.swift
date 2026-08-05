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
        /// Whether the high-quality pass produced this line, as opposed to the
        /// on-device pass during recording. Absent in payloads written before
        /// live segments were relayed at all, and every one of those carried
        /// only final segments — so a missing value means `true`.
        public var isFinal: Bool?
    }

    public var uid: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var stateRaw: String
    public var sourceRaw: String
    public var duration: TimeInterval
    public var meetingApp: String?
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
        meetingApp = session.meetingApp
        // Live segments travel too. Filtering to `isFinal` meant a recording
        // whose cloud pass hadn't landed crossed the relay as a session with an
        // empty transcript — so the phone's perfectly good on-device transcript
        // never reached the Mac, and worse, the empty payload then overwrote
        // whatever the Mac already had.
        segments = session.segments
            .sorted { $0.start < $1.start }
            .map {
                SegmentWire(text: $0.text, start: $0.start, end: $0.end,
                            channelRaw: $0.channelRaw, speakerKey: $0.speakerKey,
                            speakerName: $0.speaker?.name, isFinal: $0.isFinal)
            }
        roughMarkdown = session.note?.roughMarkdown
        enhancedMarkdown = session.note?.enhancedMarkdown
        summaryMarkdown = session.note?.summaryMarkdown
        decisionsJSON = session.note?.decisionsJSON
        actionItemsJSON = session.note?.actionItemsJSON
    }

    /// Applies wire content onto a local record. Audio is never relayed — only
    /// the transcript and notes travel.
    ///
    /// "Newer wins" decides scalar fields, but it must not decide the transcript
    /// on its own: a newer payload that happens to carry nothing is not a
    /// statement that the conversation was empty. Deleting local lines for it
    /// meant one device's failed pass could erase another device's good
    /// transcript over the network, which is the same mistake the local final
    /// pass used to make — and far harder to notice, because the words vanish on
    /// a machine that never ran anything.
    public func apply(to session: RecordingSession, context: ModelContext) {
        session.title = title
        session.createdAt = createdAt
        session.updatedAt = updatedAt
        session.stateRaw = stateRaw
        session.sourceRaw = sourceRaw
        session.duration = duration
        session.meetingApp = meetingApp

        applySegments(to: session, context: context)

        let note = session.note ?? SessionNote()
        note.roughMarkdown = roughMarkdown ?? note.roughMarkdown
        note.enhancedMarkdown = enhancedMarkdown ?? note.enhancedMarkdown
        note.summaryMarkdown = summaryMarkdown ?? note.summaryMarkdown
        note.decisionsJSON = decisionsJSON ?? note.decisionsJSON
        note.actionItemsJSON = actionItemsJSON ?? note.actionItemsJSON
        session.note = note
    }

    /// Merges the remote transcript in, refusing the two trades that lose words.
    private func applySegments(to session: RecordingSession, context: ModelContext) {
        // Nothing offered: keep what's here. An empty payload is silence about
        // the transcript, not evidence there wasn't one.
        guard !segments.isEmpty else { return }

        // Both sides have something, and ours came from the high-quality pass
        // while theirs didn't: keep ours. Otherwise a phone that only managed an
        // on-device transcript would downgrade a Mac that already has the
        // diarized one, just by being touched more recently.
        let incomingIsFinal = segments.contains { $0.isFinal ?? true }
        let localIsFinal = session.segments.contains(where: \.isFinal)
        if localIsFinal, !incomingIsFinal { return }

        for old in session.segments { context.delete(old) }
        session.segments = segments.map {
            StoredSegment(text: $0.text, start: $0.start, end: $0.end,
                          channel: CaptureChannel(rawValue: $0.channelRaw) ?? .microphone,
                          speakerKey: $0.speakerKey,
                          // Carried, not assumed. Marking a relayed live
                          // transcript as final would tell the receiving device
                          // the pass was done and stop it from ever improving it.
                          isFinal: $0.isFinal ?? true)
        }
    }
}
