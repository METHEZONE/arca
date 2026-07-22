import Foundation
import ArcaVoiceKit

/// One meeting-screen look: when it was taken and what it showed.
struct RosterSnapshot: Sendable {
    let capturedAt: Date
    let roster: MeetingRoster
}

/// Turns active-speaker sightings into transcript speaker names.
enum RosterNameMapper {
    struct TurnRef {
        let key: String
        let start: TimeInterval
        let end: TimeInterval
    }

    /// Maps diarized remote speaker keys ("Speaker 1"…) to on-screen names by
    /// majority vote: each snapshot that caught someone mid-sentence links the
    /// highlighted tile's name to whoever the transcript says was talking at
    /// that moment. Falls back to a direct match when the call had exactly one
    /// remote participant.
    static func renames(snapshots: [RosterSnapshot], startedAt: Date,
                        remoteTurns: [TurnRef], ownerName: String) -> [String: String] {
        var votes: [String: [String: Int]] = [:]
        for snapshot in snapshots {
            guard let active = snapshot.roster.activeSpeaker?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !active.isEmpty,
                  active.caseInsensitiveCompare(ownerName) != .orderedSame else { continue }
            let offset = snapshot.capturedAt.timeIntervalSince(startedAt)
            guard offset > 0 else { continue }
            guard let turn = remoteTurns.min(by: { distance($0, to: offset) < distance($1, to: offset) }),
                  distance(turn, to: offset) <= 6 else { continue }
            votes[turn.key, default: [:]][active, default: 0] += 1
        }

        // Greedy unique assignment: strongest link first, one name per key.
        var result: [String: String] = [:]
        var usedNames: Set<String> = []
        let flat = votes
            .flatMap { key, names in names.map { (key: key, name: $0.key, count: $0.value) } }
            .sorted { $0.count > $1.count }
        for vote in flat where result[vote.key] == nil && !usedNames.contains(vote.name) {
            result[vote.key] = vote.name
            usedNames.insert(vote.name)
        }

        // The common 1:1 call: one remote voice, one roster name — no vote needed.
        if result.isEmpty {
            let keys = Set(remoteTurns.map(\.key))
            let names = participantNames(in: snapshots, ownerName: ownerName)
            if keys.count == 1, names.count == 1,
               let key = keys.first, let name = names.first {
                result[key] = name
            }
        }
        return result
    }

    /// Every distinct participant name seen across the meeting (owner excluded).
    static func participantNames(in snapshots: [RosterSnapshot], ownerName: String) -> [String] {
        var seen: Set<String> = []
        var names: [String] = []
        for snapshot in snapshots {
            for raw in snapshot.roster.participants {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty,
                      name.caseInsensitiveCompare(ownerName) != .orderedSame,
                      !seen.contains(name.lowercased()) else { continue }
                seen.insert(name.lowercased())
                names.append(name)
            }
        }
        return names
    }

    private static func distance(_ turn: TurnRef, to offset: TimeInterval) -> TimeInterval {
        if offset >= turn.start && offset <= turn.end { return 0 }
        return min(abs(offset - turn.start), abs(offset - turn.end))
    }
}

#if os(macOS)
/// While a meeting records, occasionally photographs the call window and asks
/// vision who's on screen — so the transcript can carry real names instead of
/// "Speaker 1". A handful of cheap Haiku reads per meeting, nothing continuous.
@MainActor
final class MeetingRosterWatcher {
    private(set) var snapshots: [RosterSnapshot] = []
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        guard UserDefaults.standard.object(forKey: "autoRosterCapture") as? Bool ?? true else { return }
        snapshots = []
        task = Task { [weak self] in
            // Early looks catch the roster while everyone's tile is fresh;
            // later ones add active-speaker votes on long calls.
            var delays: [Duration] = [.seconds(25), .seconds(90), .seconds(240)]
            delays.append(contentsOf: Array(repeating: .seconds(300), count: 9))
            for delay in delays {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                await self.captureOnce()
            }
        }
    }

    /// Stops watching and hands back everything seen.
    func stop() -> [RosterSnapshot] {
        task?.cancel()
        task = nil
        return snapshots
    }

    private func captureOnce() async {
        guard let apiKey = KeychainStore.get(.anthropic), !apiKey.isEmpty else { return }
        guard let (data, mediaType) = await ScreenGrab.meetingWindowJPEG() else { return }
        let stamp = Date()
        guard let roster = try? await MeetingRosterReader(apiKey: apiKey)
            .read(imageData: data, mediaType: mediaType),
            !roster.participants.isEmpty || roster.activeSpeaker != nil else { return }
        snapshots.append(RosterSnapshot(capturedAt: stamp, roster: roster))
        DebugTrace.log("roster: \(roster.participants.joined(separator: ", ")) active=\(roster.activeSpeaker ?? "-")")
    }
}
#endif
