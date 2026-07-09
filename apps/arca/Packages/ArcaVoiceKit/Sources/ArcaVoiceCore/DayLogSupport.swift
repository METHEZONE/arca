import Foundation

public struct DayLogTimelineEntry: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var bundleId: String
    public var appName: String

    public init(timestamp: Date, bundleId: String, appName: String) {
        self.timestamp = timestamp
        self.bundleId = bundleId
        self.appName = appName
    }
}

public struct DayLogAppSummary: Equatable, Sendable, Identifiable {
    public var id: String { bundleId }
    public var bundleId: String
    public var appName: String
    public var seconds: TimeInterval
    public var lastActiveAt: Date

    public init(bundleId: String, appName: String, seconds: TimeInterval, lastActiveAt: Date) {
        self.bundleId = bundleId
        self.appName = appName
        self.seconds = seconds
        self.lastActiveAt = lastActiveAt
    }

    public var minutes: Int {
        max(1, Int((seconds / 60).rounded()))
    }
}

public enum DayLogTimeline {
    public static func appending(_ entry: DayLogTimelineEntry,
                                 to entries: [DayLogTimelineEntry]) -> [DayLogTimelineEntry] {
        guard entries.last?.bundleId != entry.bundleId else { return entries }
        return entries + [entry]
    }

    public static func summaries(from entries: [DayLogTimelineEntry],
                                 until endDate: Date = .now,
                                 calendar: Calendar = .current) -> [DayLogAppSummary] {
        let ordered = entries.sorted { $0.timestamp < $1.timestamp }
        var buckets: [String: (name: String, seconds: TimeInterval, last: Date)] = [:]

        for (index, entry) in ordered.enumerated() {
            let next = index + 1 < ordered.count ? ordered[index + 1].timestamp : endDate
            let rawDuration = max(0, next.timeIntervalSince(entry.timestamp))
            let duration = min(rawDuration, 30 * 60)
            var bucket = buckets[entry.bundleId] ?? (entry.appName, 0, entry.timestamp)
            bucket.name = entry.appName
            bucket.seconds += duration
            bucket.last = max(bucket.last, entry.timestamp)
            buckets[entry.bundleId] = bucket
        }

        return buckets.map { bundleId, bucket in
            DayLogAppSummary(bundleId: bundleId,
                             appName: bucket.name,
                             seconds: bucket.seconds,
                             lastActiveAt: bucket.last)
        }
        .sorted {
            if $0.seconds == $1.seconds {
                return $0.appName.localizedCompare($1.appName) == .orderedAscending
            }
            return $0.seconds > $1.seconds
        }
    }

    public static func compressedStory(from entries: [DayLogTimelineEntry],
                                       maxItems: Int = 30,
                                       calendar: Calendar = .current) -> String {
        let ordered = entries.sorted { $0.timestamp < $1.timestamp }
        guard !ordered.isEmpty else { return "타임라인 없음" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "HH:mm"
        return ordered.prefix(maxItems).map { entry in
            "\(formatter.string(from: entry.timestamp)) \(entry.appName)"
        }.joined(separator: " -> ")
    }
}

public enum DayLogSnapshotSampler {
    public static func evenlySampled<T>(_ items: [T], limit: Int) -> [T] {
        guard limit > 0, items.count > limit else { return items }
        guard limit > 1 else { return [items[0]] }

        let lastIndex = items.count - 1
        return (0..<limit).map { index in
            let position = Double(index) * Double(lastIndex) / Double(limit - 1)
            return items[Int(position.rounded())]
        }
    }
}

public enum DayDigestGuard {
    public static func dayString(for date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    public static func shouldGenerateDigest(now: Date,
                                            enabled: Bool,
                                            digestHour: Int,
                                            lastDigestDay: String?,
                                            calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        let today = dayString(for: now, calendar: calendar)
        guard lastDigestDay != today else { return false }
        return calendar.component(.hour, from: now) >= digestHour
    }
}
