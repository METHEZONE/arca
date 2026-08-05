import CryptoKit
import Foundation
import ArcaVoiceKit

/// Ships day files through the same arca-brain relay the task list and meeting
/// transcripts already ride, so the Mac can show what the iPhone measured and
/// the iPhone can write meals the Mac heard about.
///
/// Change detection is content-hash on the way out and blob-sha on the way in,
/// so a steady state costs one directory listing per sync round rather than a
/// commit every sixty seconds.
enum VitalsRelay {
    private static let directory = "vitals"
    /// Only recent days are pushed. Older days never change, and re-hashing a
    /// year of history on every heartbeat would be pure waste.
    private static let pushWindowDays = 14
    private static let pulledShasKey = "relayVitalsShas"
    private static let pushedHashesKey = "relayVitalsPushedHashes"

    /// One pull → merge → push round. Returns true when a pull changed a local
    /// file, so the caller knows to reload the UI.
    @discardableResult
    static func sync(relay: GitHubRelay, share: Bool, deviceName: String,
                     now: Date = .now, calendar: Calendar = .current) async -> Bool {
        let defaults = UserDefaults.standard
        var pulledShas = (defaults.dictionary(forKey: pulledShasKey) as? [String: String]) ?? [:]
        var pushedHashes = (defaults.dictionary(forKey: pushedHashesKey) as? [String: String]) ?? [:]

        guard let listing = try? await relay.listDirectory(path: directory) else { return false }
        var remoteShaByName: [String: String] = [:]
        for entry in listing { remoteShaByName[entry.name] = entry.sha }

        // Pull anything new or changed and merge it into the local day file.
        var changedLocally = false
        for entry in listing where pulledShas[entry.name] != entry.sha {
            guard let remote = try? await relay.pull(DailyVitals.self,
                                                     path: "\(directory)/\(entry.name)"),
                  let value = remote.value else { continue }
            if VitalsEngine.mergeRelayed(value) { changedLocally = true }
            pulledShas[entry.name] = entry.sha
        }
        defaults.set(pulledShas, forKey: pulledShasKey)

        guard share else { return changedLocally }

        // Push recent local days whose content actually changed. The fingerprint
        // covers what other devices read and excludes `updatedAt` and the
        // all-day counters, so a quiet day costs zero commits.
        for day in VitalsStore.recent(days: pushWindowDays, now: now, calendar: calendar) {
            let digest = SHA256.hash(data: Data(day.relayFingerprint.utf8))
                .map { String(format: "%02x", $0) }.joined()
            let filename = "\(day.day).json"
            guard pushedHashes[filename] != digest else { continue }
            do {
                let newSha = try await relay.push(day, path: "\(directory)/\(filename)",
                                                  sha: remoteShaByName[filename],
                                                  message: "vitals sync from \(deviceName)")
                pushedHashes[filename] = digest
                pulledShas[filename] = newSha
            } catch {
                // A conflict means the other device wrote first; the next round
                // pulls their copy, merges, and pushes the union.
                continue
            }
        }
        defaults.set(pushedHashes, forKey: pushedHashesKey)
        defaults.set(pulledShas, forKey: pulledShasKey)
        return changedLocally
    }
}
