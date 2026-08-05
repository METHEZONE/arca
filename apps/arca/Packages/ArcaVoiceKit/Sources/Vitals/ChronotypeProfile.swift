import Foundation
import ArcaVoiceCore

/// One observed stretch of focused work. The chronotype profile is built only
/// from these, so every claim about when the user focuses best is traceable to
/// stretches ARCA actually watched happen.
public struct FocusEvidence: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var minutes: Double
    /// 0–1. How unbroken the stretch was.
    public var quality: Double
    /// "zone" | "daylog" | "deepmeasure"
    public var source: String

    public init(startedAt: Date, minutes: Double, quality: Double, source: String) {
        self.startedAt = startedAt
        self.minutes = minutes
        self.quality = quality
        self.source = source
    }
}

/// Answers "when am I actually sharpest?" by bucketing observed focus stretches
/// into hours of the day and normalizing against the user's own best hour.
///
/// It deliberately reports nothing until there is enough evidence. A confident
/// "you peak at 3pm" drawn from two afternoons would send the user rearranging
/// their life around noise.
public enum ChronotypeProfile {
    /// Focus minutes in one hour, on an average observed day, that count as a
    /// fully-used hour. Above this the bucket is saturated.
    public static let saturationMinutesPerDay = 40.0

    /// Total observed focus minutes required before a profile is published.
    public static let minimumTotalMinutes = 180

    /// Apps that are real work but not deep work, plus outright leisure. A
    /// stretch in one of these is not counted as focus. Overridable — it's a
    /// heuristic, not a truth.
    public static let defaultNonFocusBundleIDs: Set<String> = [
        "com.apple.MobileSMS",
        "com.apple.iChat",
        "com.apple.FaceTime",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.apple.Music",
        "com.spotify.client",
        "com.apple.TV",
        "com.netflix.Netflix",
        "com.apple.systempreferences",
        "com.apple.finder",
        "com.apple.loginwindow",
    ]

    // MARK: - Building the profile

    /// Buckets evidence into the 24 hours of the day. `score` is relative to
    /// the user's strongest hour, so it reads as "when", not "how much".
    /// Returns an empty profile until `minimumTotalMinutes` of evidence exists.
    public static func windows(from evidence: [FocusEvidence],
                               calendar: Calendar = .current,
                               minimumTotalMinutes: Int = minimumTotalMinutes) -> [FocusWindow] {
        guard !evidence.isEmpty else { return [] }

        var minutesByHour = [Int: Double]()
        var weightedQualityByHour = [Int: Double]()
        var observedDays = Set<String>()

        for item in evidence where item.minutes > 0 {
            observedDays.insert(VitalsFormat.dayKey(for: item.startedAt, calendar: calendar))
            for slice in hourSlices(of: item, calendar: calendar) {
                minutesByHour[slice.hour, default: 0] += slice.minutes
                weightedQualityByHour[slice.hour, default: 0] += slice.minutes * item.quality
            }
        }

        let totalMinutes = minutesByHour.values.reduce(0, +)
        guard Int(totalMinutes) >= minimumTotalMinutes else { return [] }

        let dayCount = Double(max(1, observedDays.count))
        var strengthByHour = [Int: Double]()
        for (hour, minutes) in minutesByHour where minutes > 0 {
            let averageQuality = weightedQualityByHour[hour, default: 0] / minutes
            let volume = min(1.0, (minutes / dayCount) / saturationMinutesPerDay)
            strengthByHour[hour] = averageQuality * volume
        }

        guard let peak = strengthByHour.values.max(), peak > 0 else { return [] }

        return strengthByHour
            .map { hour, strength in
                FocusWindow(hour: hour,
                            score: strength / peak,
                            minutesObserved: Int(minutesByHour[hour, default: 0].rounded()))
            }
            .sorted { $0.hour < $1.hour }
    }

    /// The user's strongest hours, filtered so a bucket with almost no evidence
    /// behind it can never top the list.
    public static func best(_ windows: [FocusWindow], count: Int = 3,
                            minimumMinutes: Int = 30) -> [FocusWindow] {
        windows
            .filter { $0.minutesObserved >= minimumMinutes }
            .sorted { lhs, rhs in
                lhs.score == rhs.score ? lhs.hour < rhs.hour : lhs.score > rhs.score
            }
            .prefix(count)
            .sorted { $0.hour < $1.hour }
    }

    /// The next hour today (or tomorrow) that the user reliably focuses in.
    public static func nextWindow(after date: Date, windows: [FocusWindow],
                                  threshold: Double = 0.7,
                                  minimumMinutes: Int = 30,
                                  calendar: Calendar = .current) -> FocusWindow? {
        let strong = windows
            .filter { $0.score >= threshold && $0.minutesObserved >= minimumMinutes }
        guard !strong.isEmpty else { return nil }
        let currentHour = calendar.component(.hour, from: date)
        return strong.first { $0.hour > currentHour } ?? strong.first
    }

    /// The four focus buckets ARCA already asks about during onboarding.
    ///
    /// Reused verbatim rather than re-minted: the user was first asked which of
    /// these they are, so the measured answer has to come back in the same
    /// words. A fifth vocabulary for "morning person" would make the measurement
    /// look unrelated to the question.
    public enum FocusBucket: String, Codable, Sendable, CaseIterable {
        case morning, afternoon, night, wild

        public var label: String {
            switch self {
            case .morning: return L("아침 — 세상이 조용할 때", "Morning — while the world is quiet")
            case .afternoon: return L("오후 — 엔진이 데워진 뒤", "Afternoon — once the engine is warm")
            case .night: return L("밤 — 방해가 사라진 뒤", "Night — after the interruptions stop")
            case .wild: return L("불규칙 — 몰입이 오면 그때", "Irregular — whenever focus shows up")
            }
        }

        static func containing(hour: Int) -> FocusBucket {
            switch hour {
            case 5..<11: return .morning
            case 11..<17: return .afternoon
            default: return .night
            }
        }
    }

    /// Which bucket the user's measured peak actually falls in, or `.wild` when
    /// no single stretch of the day owns it. Nil until there's a profile at all —
    /// guessing "아침형" from nothing is worse than admitting we don't know.
    public static func dominantBucket(_ windows: [FocusWindow],
                                      minimumMinutes: Int = 30) -> FocusBucket? {
        let usable = windows.filter { $0.minutesObserved >= minimumMinutes && $0.score > 0 }
        guard !usable.isEmpty else { return nil }

        var weightByBucket: [FocusBucket: Double] = [:]
        for window in usable {
            let weight = window.score * Double(window.minutesObserved)
            weightByBucket[.containing(hour: window.hour), default: 0] += weight
        }
        let total = weightByBucket.values.reduce(0, +)
        guard total > 0, let top = weightByBucket.max(by: { $0.value < $1.value }) else { return nil }
        // No clear owner of the day reads as irregular, which is a real answer
        // and one of the four the user was offered.
        return top.value / total >= 0.5 ? top.key : .wild
    }

    /// A Korean one-liner describing the peak, merging adjacent hours into
    /// ranges so it reads like a person said it.
    public static func narrative(_ windows: [FocusWindow], minimumMinutes: Int = 30) -> String {
        let peaks = best(windows, count: 4, minimumMinutes: minimumMinutes)
        guard !peaks.isEmpty else {
            return L("아직 몰입 패턴을 만들 데이터가 부족해요.",
                     "Not enough data yet to map your focus pattern.")
        }
        let ranges = mergeIntoRanges(peaks.map(\.hour))
        let phrase = ranges.map(rangeLabel).joined(separator: ", ")
        return L("\(phrase)에 가장 깊게 몰입해요.", "You focus deepest around \(phrase).")
    }

    // MARK: - Evidence sources

    /// Turns the Mac's app-switch timeline into focus stretches.
    ///
    /// The timeline records only switches, so the gap between two entries is
    /// how long the earlier app was in front. That has a known blind spot: if
    /// the user walks away and comes back to the same app, nothing is written
    /// and the gap looks like one enormous stretch. `maximumStretchMinutes`
    /// truncates those rather than crediting an empty desk as deep work.
    public static func evidence(fromTimeline entries: [DayLogTimelineEntry],
                                until endDate: Date,
                                minimumStretchMinutes: Double = 12,
                                maximumStretchMinutes: Double = 75,
                                fullQualityMinutes: Double = 30,
                                nonFocusBundleIDs: Set<String> = defaultNonFocusBundleIDs) -> [FocusEvidence] {
        let ordered = entries.sorted { $0.timestamp < $1.timestamp }
        var result: [FocusEvidence] = []

        for (index, entry) in ordered.enumerated() {
            guard !nonFocusBundleIDs.contains(entry.bundleId) else { continue }
            let next = index + 1 < ordered.count ? ordered[index + 1].timestamp : endDate
            let rawMinutes = next.timeIntervalSince(entry.timestamp) / 60
            guard rawMinutes >= minimumStretchMinutes else { continue }
            let minutes = min(rawMinutes, maximumStretchMinutes)
            result.append(FocusEvidence(
                startedAt: entry.timestamp,
                minutes: minutes,
                quality: min(1.0, minutes / fullQualityMinutes),
                source: "daylog"))
        }
        return result
    }

    /// ZONE sessions are the strongest evidence there is — the user explicitly
    /// declared they were focusing, and ARCA counted what broke through.
    public static func evidence(fromSessions sessions: [FocusSession]) -> [FocusEvidence] {
        sessions.compactMap { session in
            let minutes = Double(session.minutes)
            guard minutes >= 5 else { return nil }
            return FocusEvidence(startedAt: session.startedAt,
                                 minutes: minutes,
                                 quality: session.quality,
                                 source: session.source)
        }
    }

    // MARK: - Helpers

    struct HourSlice {
        var hour: Int
        var minutes: Double
    }

    /// Splits a stretch across the clock hours it actually spans, so a 90-minute
    /// block starting at 10:40 credits 20 minutes to 10:00 and 60 to 11:00
    /// rather than dumping all 90 into whichever hour it happened to start in.
    static func hourSlices(of evidence: FocusEvidence, calendar: Calendar) -> [HourSlice] {
        var slices: [HourSlice] = []
        var cursor = evidence.startedAt
        var remaining = evidence.minutes
        var guardCount = 0

        while remaining > 0.01 && guardCount < 48 {
            guardCount += 1
            let hour = calendar.component(.hour, from: cursor)
            // Walk to the top of the next hour via date components rather than
            // adding 3600 seconds, so DST transitions don't shift the buckets.
            let hourStart = calendar.date(from: calendar.dateComponents(
                [.year, .month, .day, .hour], from: cursor)) ?? cursor
            let nextBoundary = calendar.date(byAdding: .hour, value: 1, to: hourStart)
                ?? cursor.addingTimeInterval(3600)
            let minutesToBoundary = max(0.01, nextBoundary.timeIntervalSince(cursor) / 60)
            let used = min(remaining, minutesToBoundary)
            slices.append(HourSlice(hour: hour, minutes: used))
            remaining -= used
            cursor = cursor.addingTimeInterval(used * 60)
        }
        return slices
    }

    static func mergeIntoRanges(_ hours: [Int]) -> [ClosedRange<Int>] {
        let sorted = hours.sorted()
        guard var start = sorted.first else { return [] }
        var previous = start
        var ranges: [ClosedRange<Int>] = []

        for hour in sorted.dropFirst() {
            if hour == previous + 1 {
                previous = hour
                continue
            }
            ranges.append(start...previous)
            start = hour
            previous = hour
        }
        ranges.append(start...previous)
        return ranges
    }

    static func rangeLabel(_ range: ClosedRange<Int>) -> String {
        let endHour = (range.upperBound + 1) % 24
        if range.lowerBound == range.upperBound {
            return "\(koreanHour(range.lowerBound))"
        }
        return "\(koreanHour(range.lowerBound))–\(koreanHour(endHour))"
    }

    static func koreanHour(_ hour: Int) -> String {
        switch hour {
        case 0: return L("자정", "midnight")
        case 1..<12: return L("오전 \(hour)시", "\(hour)am")
        case 12: return L("정오", "noon")
        default: return L("오후 \(hour - 12)시", "\(hour - 12)pm")
        }
    }
}
