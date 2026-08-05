import Foundation
import Observation
import ArcaVoiceKit

/// One device's "I'm here" stamp, exchanged through the relay.
///
/// The point is emotional as much as technical: the Mac and the iPhone were
/// already sharing a task list, a transcript library, and now a body — but
/// neither app ever *said* so, so they read as two separate products that
/// happened to have similar data. This makes the other device visible.
struct DeviceHeartbeat: Codable, Equatable, Sendable, Identifiable {
    /// "mac" | "iphone" — the same vocabulary the relay already uses.
    var device: String
    var lastSeenAt: Date
    var appVersion: String
    var systemVersion: String
    /// Set while a focus session is running on that device, so the other one can
    /// say "맥에서 ZONE 42분째" instead of pretending nothing is happening.
    var zoneStartedAt: Date?
    var isRecording: Bool?

    var id: String { device }

    /// Optional so an older build's heartbeat still decodes.
    var isInZone: Bool { zoneStartedAt != nil }

    func zoneMinutes(now: Date = .now) -> Int? {
        guard let zoneStartedAt else { return nil }
        return max(0, Int(now.timeIntervalSince(zoneStartedAt) / 60))
    }

    /// One line describing what this device is doing right now, or nil when it's
    /// just idling — an idle device shouldn't generate chatter.
    func activityLine(now: Date = .now) -> String? {
        if let minutes = zoneMinutes(now: now) {
            return L("ZONE \(minutes)분째", "\(minutes) min in the ZONE")
        }
        if isRecording == true {
            return L("녹음 중", "Recording")
        }
        return nil
    }

    var displayName: String {
        switch device {
        case "mac": return L("맥", "Mac")
        case "iphone": return L("아이폰", "iPhone")
        default: return device
        }
    }

    var symbol: String {
        switch device {
        case "mac": return "laptopcomputer"
        case "iphone": return "iphone"
        default: return "desktopcomputer"
        }
    }

    /// This is the device the user is looking at right now.
    var isSelf: Bool { device == VitalsDevice.current }

    /// Treated as awake if it checked in within the last half hour — long enough
    /// that a phone in a pocket still counts, short enough to be meaningful.
    func isRecent(now: Date = .now) -> Bool {
        now.timeIntervalSince(lastSeenAt) < 30 * 60
    }
}

/// Tracks which of the user's devices are alive, via one small file per device
/// in the relay.
@MainActor
@Observable
final class DevicePresence {
    static let shared = DevicePresence()

    /// Every device that has ever checked in, this one first.
    private(set) var devices: [DeviceHeartbeat] = []

    /// Peers other than the device being used right now.
    var peers: [DeviceHeartbeat] {
        devices.filter { !$0.isSelf }
    }

    /// A peer that's currently awake, if any — the one worth naming in the UI.
    var activePeer: DeviceHeartbeat? {
        peers.first { $0.isRecent() }
    }

    @ObservationIgnored private var lastPushedAt: Date?
    @ObservationIgnored private var lastPulledAt: Date?

    /// Heartbeats are pushed at most this often. The relay is a git repo; a
    /// commit every sync round would bury the actual content in noise.
    private static let pushInterval: TimeInterval = 15 * 60

    /// And read at most this often. The Mac's sync loop runs every 60 seconds;
    /// a directory listing plus a read per device on every pass would spend
    /// close to two hundred GitHub calls an hour to answer a question that
    /// changes every few minutes at most.
    private static let pullInterval: TimeInterval = 5 * 60

    fileprivate func apply(_ records: [DeviceHeartbeat]) {
        devices = records.sorted { lhs, rhs in
            if lhs.isSelf != rhs.isSelf { return lhs.isSelf }
            return lhs.lastSeenAt > rhs.lastSeenAt
        }
    }

    fileprivate func shouldPush(now: Date) -> Bool {
        guard let lastPushedAt else { return true }
        return now.timeIntervalSince(lastPushedAt) >= Self.pushInterval
    }

    fileprivate func markPushed(at date: Date) {
        lastPushedAt = date
    }

    fileprivate func shouldPull(now: Date) -> Bool {
        guard let lastPulledAt else { return true }
        return now.timeIntervalSince(lastPulledAt) >= Self.pullInterval
    }

    fileprivate func markPulled(at date: Date) {
        lastPulledAt = date
    }

    /// Keeps this device's own stamp fresh without touching the network, so the
    /// bar is never wrong about the machine you're holding.
    fileprivate func refreshSelf(now: Date = .now) {
        var records = devices.filter { $0.device != VitalsDevice.current }
        records.append(DevicePresence.selfHeartbeat(now: now))
        apply(records)
    }

    /// `nonisolated` because the relay builds this off the main actor; it only
    /// reads immutable bundle and process info.
    nonisolated static func selfHeartbeat(now: Date = .now) -> DeviceHeartbeat {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return DeviceHeartbeat(
            device: VitalsDevice.current,
            lastSeenAt: now,
            appVersion: version,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            zoneStartedAt: liveZoneStartedAt,
            isRecording: liveIsRecording)
    }

    /// Read off the main actor via a mirror the app keeps up to date, so building
    /// a heartbeat from the relay's background work never has to hop actors.
    nonisolated(unsafe) private static var liveZoneStartedAt: Date?
    nonisolated(unsafe) private static var liveIsRecording = false

    /// Called by the app whenever focus or recording state changes.
    ///
    /// Also arms an immediate heartbeat: the 15-minute cadence is right for "I'm
    /// still here", but "I just started a ZONE" is only useful on the other device
    /// if it lands now.
    @MainActor
    static func reportActivity(zoneStartedAt: Date?, isRecording: Bool) {
        let changed = liveZoneStartedAt != zoneStartedAt || liveIsRecording != isRecording
        liveZoneStartedAt = zoneStartedAt
        liveIsRecording = isRecording
        guard changed else { return }
        shared.refreshSelf()
        shared.armImmediatePush()
        RelaySync.shared.scheduleSync(after: 2)
    }

    /// Lets the next sync round push regardless of how recently one went out.
    fileprivate func armImmediatePush() {
        lastPushedAt = nil
    }
}

/// Relay plumbing for presence — deliberately separate from the vitals sync so a
/// heartbeat is never the reason a health file gets pushed, or vice versa.
enum DevicePresenceRelay {
    private static let directory = "devices"

    static func sync(relay: GitHubRelay, now: Date = .now) async {
        let mine = DevicePresence.selfHeartbeat(now: now)
        let (shouldPull, shouldPush) = await MainActor.run {
            let presence = DevicePresence.shared
            // The local device's own stamp costs nothing to keep current.
            presence.refreshSelf(now: now)
            return (presence.shouldPull(now: now), presence.shouldPush(now: now))
        }

        if shouldPush {
            let filename = "\(mine.device).json"
            // One pull for the blob sha, then the write. Skipped entirely on the
            // rounds where the heartbeat isn't due.
            let existingSha = try? await relay.pull(DeviceHeartbeat.self,
                                                    path: "\(directory)/\(filename)").sha
            do {
                try await relay.push(mine, path: "\(directory)/\(filename)",
                                     sha: existingSha ?? nil,
                                     message: "\(mine.device) checking in")
                await MainActor.run { DevicePresence.shared.markPushed(at: now) }
            } catch {
                // A missed heartbeat is cosmetic; never surface it as an error.
            }
        }

        guard shouldPull else { return }

        var records: [DeviceHeartbeat] = []
        if let listing = try? await relay.listDirectory(path: directory) {
            for entry in listing where entry.name.hasSuffix(".json") {
                guard let remote = try? await relay.pull(DeviceHeartbeat.self,
                                                         path: "\(directory)/\(entry.name)"),
                      let value = remote.value else { continue }
                records.append(value)
            }
        }
        // Ours always wins for our own row — it's live, the relayed copy is not.
        records.removeAll { $0.device == mine.device }
        records.append(mine)

        await MainActor.run {
            DevicePresence.shared.apply(records)
            DevicePresence.shared.markPulled(at: now)
        }
    }
}
