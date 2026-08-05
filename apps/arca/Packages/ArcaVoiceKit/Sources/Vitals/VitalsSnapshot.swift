import Foundation
import ArcaVoiceCore

/// The small, flat version of today that a widget can read.
///
/// Widgets run in their own process and cannot reach the app's container, so the
/// full day files are invisible to them. Rather than give the widget extension
/// access to everything, the app writes this one deliberately minimal record into
/// the shared App Group after each refresh: the numbers a glance needs and
/// nothing else. A widget has no business holding the user's sleep architecture
/// or their meal log.
public struct VitalsSnapshot: Codable, Equatable, Sendable {
    public var updatedAt: Date
    /// Readiness, or live focus depth when a measurement is recent.
    public var ringScore: Int?
    public var isLive: Bool
    /// Localized already — the widget has no access to the app's language helper.
    public var label: String
    /// e.g. "10:00–11:00", or nil when the profile can't name one yet.
    public var nextWindowLabel: String?
    public var sleepMinutes: Int?
    public var stress: Int?
    /// Focus minutes recorded this week.
    public var weeklyZoneMinutes: Int?
    /// Interruptions ARCA absorbed this week.
    public var weeklyAbsorbed: Int?

    public init(updatedAt: Date = .now, ringScore: Int? = nil, isLive: Bool = false,
                label: String = "", nextWindowLabel: String? = nil,
                sleepMinutes: Int? = nil, stress: Int? = nil,
                weeklyZoneMinutes: Int? = nil, weeklyAbsorbed: Int? = nil) {
        self.updatedAt = updatedAt
        self.ringScore = ringScore
        self.isLive = isLive
        self.label = label
        self.nextWindowLabel = nextWindowLabel
        self.sleepMinutes = sleepMinutes
        self.stress = stress
        self.weeklyZoneMinutes = weeklyZoneMinutes
        self.weeklyAbsorbed = weeklyAbsorbed
    }

    public var hasAnything: Bool {
        ringScore != nil || sleepMinutes != nil || weeklyZoneMinutes != nil
    }
}

/// Reads and writes the widget snapshot in the shared App Group container.
///
/// Both sides use this: the app writes, the widget extension reads. Failures are
/// silent by design — a missing snapshot means the widget shows its empty state,
/// which is a normal condition (fresh install, no permission yet), not an error
/// worth surfacing.
public enum VitalsSnapshotStore {
    private static let fileName = "vitals-snapshot.json"

    private static var url: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedInbox.appGroupID) else { return nil }
        return container.appendingPathComponent(fileName)
    }

    public static func write(_ snapshot: VitalsSnapshot) {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func read() -> VitalsSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(VitalsSnapshot.self, from: data)
    }
}
