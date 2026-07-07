import Foundation
import ArcaVoiceCore

/// Portable snapshot of a session for sync/export.
/// v1 backend is CloudKit via SwiftData mirroring; this protocol exists so the
/// ARCA company-brain backend can plug in later without touching the models.
public struct SessionSnapshot: Sendable, Codable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var transcriptMarkdown: String
    public var notes: MeetingNotes?

    public init(id: UUID, title: String, createdAt: Date, transcriptMarkdown: String, notes: MeetingNotes?) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.transcriptMarkdown = transcriptMarkdown
        self.notes = notes
    }
}

public protocol SyncBackend: Sendable {
    func push(_ snapshot: SessionSnapshot) async throws
    func pull(since: Date) async throws -> [SessionSnapshot]
}
