import Foundation

/// Someone expected in a meeting, known before a word is recorded.
///
/// Lives in `ArcaVoiceCore` rather than `Intelligence` because the stored model
/// in `Store` has to hold these, and `Store` depends on core alone.
///
/// Knowing the names up front pays off even with no speaker separation at all:
/// they go to the recognizer as expected vocabulary, so Korean names stop coming
/// back as homophones; they stay on the record as who was in the room; and they
/// become the addresses the minutes get sent to.
public struct MeetingParticipant: Sendable, Codable, Equatable, Hashable, Identifiable {
    /// Where the name came from, so the UI can show what it inferred versus
    /// what the user typed — and so a wrong guess is obvious rather than
    /// looking like something the user asserted.
    public enum Origin: String, Sendable, Codable {
        case typed
        case calendar
        /// Read off a meeting app's participant tiles (macOS).
        case screen
    }

    public var name: String
    public var email: String?
    public var origin: Origin

    /// Email wins when present: the same person typed by hand and pulled from a
    /// calendar invite must collapse to one entry, and their display names
    /// routinely differ ("민성" vs "박민성").
    public var id: String {
        if let email, !email.isEmpty { return email.lowercased() }
        return name.lowercased()
    }

    public init(name: String, email: String? = nil, origin: Origin = .typed) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.email = (trimmedEmail?.isEmpty == false) ? trimmedEmail : nil
        self.origin = origin
    }
}

extension Array where Element == MeetingParticipant {
    /// Adds without duplicating, preferring the entry that carries more.
    ///
    /// A typed name and a calendar invite for the same person should end as one
    /// participant holding both the name the user recognizes and the address the
    /// minutes can go to.
    public func merging(_ incoming: [MeetingParticipant]) -> [MeetingParticipant] {
        var result = self
        for candidate in incoming where !candidate.name.isEmpty {
            // Not `id` equality: the common case is a name typed with no address and
            // then the same person pulled from an invite *with* one, and those
            // two have different ids by construction. Two addresses that differ
            // really are two people, even under one name; otherwise fall back to
            // the name.
            let index = result.firstIndex { existing in
                if let existingEmail = existing.email?.lowercased(),
                   let candidateEmail = candidate.email?.lowercased() {
                    return existingEmail == candidateEmail
                }
                return existing.name.caseInsensitiveCompare(candidate.name) == .orderedSame
            }
            guard let index else {
                result.append(candidate)
                continue
            }
            if result[index].email == nil, let email = candidate.email {
                result[index].email = email
            }
            // A hand-typed name is the one the user will recognize; never let a
            // calendar's "MIN SUNG PARK" overwrite it.
            if result[index].origin != .typed, candidate.origin == .typed {
                result[index].name = candidate.name
                result[index].origin = .typed
            }
        }
        return result
    }

    /// Names for the recognizer, owner excluded — the owner's own name is not
    /// something they say aloud.
    public func vocabulary(excluding ownerName: String) -> [String] {
        compactMap { participant in
            let name = participant.name
            guard !name.isEmpty,
                  name.caseInsensitiveCompare(ownerName) != .orderedSame else { return nil }
            return name
        }
    }
}
