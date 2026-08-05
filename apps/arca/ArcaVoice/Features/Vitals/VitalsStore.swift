import Foundation
import ArcaVoiceKit

/// Which device this build is running on, in the two-value vocabulary the relay
/// and the merge rules use.
enum VitalsDevice {
    static var current: String {
        #if os(macOS)
        return "mac"
        #else
        return "iphone"
        #endif
    }
}

/// One JSON document per day under Application Support, mirroring how the day
/// log stores its timeline.
///
/// Deliberately not SwiftData: this is day-keyed time series that already has a
/// natural file boundary, the relay ships whole days as single blobs, and adding
/// `@Model` types would mean a schema migration on a store that holds the user's
/// real recordings. A corrupt file here can cost at most one day of vitals.
enum VitalsStore {
    private static let coachFileName = "coach.json"

    static var root: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        #if ARCA_TEST_BUILD
        return support
            .appendingPathComponent("ArcaVoiceTest", isDirectory: true)
            .appendingPathComponent("vitals", isDirectory: true)
        #else
        let base = support.appendingPathComponent("ArcaVoice", isDirectory: true)
        let accountId = AccountStore.currentAccountId()
        guard !AccountStore.isDefault(accountId) else {
            return base.appendingPathComponent("vitals", isDirectory: true)
        }
        return base
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(accountId, isDirectory: true)
            .appendingPathComponent("vitals", isDirectory: true)
        #endif
    }

    // MARK: - Days

    static func load(day: String) -> DailyVitals? {
        let url = root.appendingPathComponent("\(day).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder().decode(DailyVitals.self, from: data)
    }

    static func save(_ vitals: DailyVitals) {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let data = try encoder().encode(vitals)
            try data.write(to: root.appendingPathComponent("\(vitals.day).json"), options: .atomic)
        } catch {
            NSLog("[ARCA vitals] day write failed for %@: %@", vitals.day, "\(error)")
        }
    }

    /// Loads a day, hands it to `mutate`, writes it back. Creates the day if it
    /// doesn't exist yet.
    @discardableResult
    static func upsert(day: String, _ mutate: (inout DailyVitals) -> Void) -> DailyVitals {
        var vitals = load(day: day) ?? DailyVitals(day: day, device: VitalsDevice.current)
        mutate(&vitals)
        save(vitals)
        return vitals
    }

    /// The last `days` days that have a file, ordered oldest → newest. Baselines
    /// depend on that ordering, so it's guaranteed here rather than at each call
    /// site.
    static func recent(days: Int, now: Date = .now, calendar: Calendar = .current) -> [DailyVitals] {
        let today = calendar.startOfDay(for: now)
        return (0..<max(1, days)).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return load(day: VitalsFormat.dayKey(for: date, calendar: calendar))
        }
    }

    static func dayKeys() -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return contents
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != coachFileName }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// Keeps the store from growing without bound. A year and a bit is well past
    /// anything the profile or the coach reads.
    static func prune(keepDays: Int = 400, now: Date = .now, calendar: Calendar = .current) {
        guard let cutoff = calendar.date(byAdding: .day, value: -keepDays, to: now) else { return }
        let cutoffKey = VitalsFormat.dayKey(for: cutoff, calendar: calendar)
        for key in dayKeys() where key < cutoffKey {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("\(key).json"))
        }
    }

    // MARK: - Coach

    static func loadCoach() -> VitalsCoachResult? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(coachFileName)) else {
            return nil
        }
        return try? decoder().decode(VitalsCoachResult.self, from: data)
    }

    static func save(coach: VitalsCoachResult) {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let data = try encoder().encode(coach)
            try data.write(to: root.appendingPathComponent(coachFileName), options: .atomic)
        } catch {
            NSLog("[ARCA vitals] coach write failed: %@", "\(error)")
        }
    }

    // MARK: - Coding

    /// ISO-8601 dates so the relayed file is readable as a diff in the repo,
    /// and so the same document decodes identically on every device.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
