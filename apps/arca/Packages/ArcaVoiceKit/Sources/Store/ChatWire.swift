import Foundation
import SwiftData

/// Wire format for relaying one conversation between devices.
///
/// Chat was the most glaring hole in "it's the same app": a conversation held on
/// the Mac simply did not exist on the phone, even though tasks and transcripts
/// had been syncing for weeks.
///
/// Two deliberate omissions:
///
/// - **Images stay home.** A turn can carry a full screenshot; shipping those
///   through a git-backed relay would bloat it fast, for the same reason meeting
///   audio never leaves the device that recorded it. The wire records only that
///   an image *was* there, so the other device can say so rather than silently
///   showing a turn with the subject missing.
/// - **No new identity column.** `ChatLogEntry` has no uid, and adding one would
///   mean a schema migration on a store holding the user's real history. Role
///   plus millisecond timestamp inside a conversation is already unique — two
///   turns from the same speaker in the same millisecond don't happen — so the
///   merge key is derived instead of stored.
public struct ChatWire: Codable, Sendable, Equatable {
    public struct Turn: Codable, Sendable, Equatable {
        public var role: String
        public var text: String
        public var createdAt: Date
        public var hadImage: Bool

        public init(role: String, text: String, createdAt: Date, hadImage: Bool) {
            self.role = role
            self.text = text
            self.createdAt = createdAt
            self.hadImage = hadImage
        }

        /// Stable within a conversation, and identical on both devices because
        /// it's derived from values that never change after insertion.
        public var key: String {
            "\(role)|\(Int((createdAt.timeIntervalSince1970 * 1000).rounded()))"
        }
    }

    public var conversationId: String
    public var projectName: String?
    public var updatedAt: Date
    public var turns: [Turn]

    public init(conversationId: String, projectName: String?, updatedAt: Date, turns: [Turn]) {
        self.conversationId = conversationId
        self.projectName = projectName
        self.updatedAt = updatedAt
        self.turns = turns
    }

    /// Builds a wire from the local rows of one conversation.
    public init(conversationId: String, entries: [ChatLogEntry]) {
        let ordered = entries.sorted { $0.createdAt < $1.createdAt }
        self.conversationId = conversationId
        self.projectName = ordered.compactMap(\.projectName).first { !$0.isEmpty }
        self.updatedAt = ordered.last?.createdAt ?? .distantPast
        self.turns = ordered.map {
            Turn(role: $0.roleRaw, text: $0.text, createdAt: $0.createdAt,
                 hadImage: $0.imageData != nil)
        }
    }

    /// Inserts turns this device has never seen. Union rather than replace: each
    /// side may hold turns the other doesn't, and a conversation continued on two
    /// devices should end up with both halves rather than whichever synced last.
    ///
    /// Returns the number of turns actually added.
    @discardableResult
    public func merge(into existing: [ChatLogEntry], context: ModelContext) -> Int {
        var seen = Set(existing.map { entry in
            Turn(role: entry.roleRaw, text: entry.text, createdAt: entry.createdAt,
                 hadImage: entry.imageData != nil).key
        })

        var added = 0
        for turn in turns where !seen.contains(turn.key) {
            seen.insert(turn.key)
            context.insert(ChatLogEntry(
                role: turn.role,
                // Marked so a turn whose screenshot stayed on the other device
                // doesn't read as if ARCA answered nothing.
                text: turn.hadImage && turn.text.isEmpty
                    ? "(이미지는 원래 기기에 있어요)"
                    : turn.text,
                conversationId: conversationId,
                projectName: projectName,
                imageData: nil,
                createdAt: turn.createdAt))
            added += 1
        }

        // A project assigned on one device should show up on the other.
        if let projectName, !projectName.isEmpty {
            for entry in existing where entry.projectName?.isEmpty ?? true {
                entry.projectName = projectName
            }
        }
        return added
    }

    /// Content fingerprint for push change-detection — excludes nothing, because
    /// unlike vitals a chat only changes when a turn is actually added.
    public var fingerprint: String {
        turns.map(\.key).joined(separator: ",") + "|" + (projectName ?? "")
    }
}
