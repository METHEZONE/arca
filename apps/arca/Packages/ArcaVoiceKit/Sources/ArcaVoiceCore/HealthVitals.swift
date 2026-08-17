#if canImport(HealthKit)
import Foundation
import HealthKit

/// Reads the body's side of the story from Apple Health.
///
/// ARCA already knows what the user *said*; this is what their body was doing
/// while they said it. The point isn't a dashboard of numbers — it's that a
/// voice note about feeling detached can sit next to that day's HRV and sleep,
/// so patterns become visible over weeks instead of being re-litigated from
/// memory every time.
///
/// Read-only and on-device. Nothing here is uploaded: HealthKit data stays on
/// the phone, and only the short summary line the user chooses to attach ever
/// reaches a model. HealthKit itself is iOS/watchOS only, which is why this
/// whole file is behind `canImport`.
///
/// Every value is optional and stays nil when Health has nothing — a missing
/// reading is reported as missing rather than as a zero, because "no data" and
/// "resting heart rate of 0" mean very different things.
public actor HealthVitals {
    public static let shared = HealthVitals()

    /// One day's worth of the signals that matter for how someone felt.
    ///
    /// Chosen for a companion tracking mood and dissociation rather than
    /// fitness: HRV and resting heart rate are the standard proxies for
    /// autonomic stress, sleep and respiration shape how the next day goes,
    /// and mindful minutes are the one entry the user logs deliberately.
    public struct DayVitals: Sendable, Equatable {
        public var date: Date
        /// Heart-rate variability (SDNN, ms). Lower usually tracks with more
        /// physiological stress.
        public var hrvSDNN: Double?
        public var restingHeartRate: Double?
        public var respiratoryRate: Double?
        /// Time actually asleep, in hours — not time in bed.
        public var sleepHours: Double?
        public var mindfulMinutes: Double?
        public var steps: Double?

        public init(date: Date, hrvSDNN: Double? = nil, restingHeartRate: Double? = nil,
                    respiratoryRate: Double? = nil, sleepHours: Double? = nil,
                    mindfulMinutes: Double? = nil, steps: Double? = nil) {
            self.date = date
            self.hrvSDNN = hrvSDNN
            self.restingHeartRate = restingHeartRate
            self.respiratoryRate = respiratoryRate
            self.sleepHours = sleepHours
            self.mindfulMinutes = mindfulMinutes
            self.steps = steps
        }

        public var isEmpty: Bool {
            hrvSDNN == nil && restingHeartRate == nil && respiratoryRate == nil
                && sleepHours == nil && mindfulMinutes == nil && steps == nil
        }

        /// One line ARCA can actually read out or attach to a note. Skips
        /// whatever's missing instead of printing placeholders.
        public var summaryLine: String {
            var parts: [String] = []
            if let sleepHours {
                parts.append(String(format: "수면 %.1f시간", sleepHours))
            }
            if let hrvSDNN {
                parts.append("HRV \(Int(hrvSDNN.rounded()))ms")
            }
            if let restingHeartRate {
                parts.append("안정 심박 \(Int(restingHeartRate.rounded()))")
            }
            if let mindfulMinutes, mindfulMinutes > 0 {
                parts.append("마음챙김 \(Int(mindfulMinutes.rounded()))분")
            }
            if let steps, steps > 0 {
                parts.append("\(Int(steps.rounded()))걸음")
            }
            return parts.isEmpty ? "건강 데이터 없음" : parts.joined(separator: " · ")
        }
    }

    private let store = HKHealthStore()

    public static var isSupported: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Types ARCA asks to read. Deliberately short — asking for everything
    /// makes the permission sheet look invasive and most of it would go unused.
    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        if let t = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) { types.insert(t) }
        if let t = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) { types.insert(t) }
        if let t = HKQuantityType.quantityType(forIdentifier: .respiratoryRate) { types.insert(t) }
        if let t = HKQuantityType.quantityType(forIdentifier: .stepCount) { types.insert(t) }
        if let t = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(t) }
        if let t = HKCategoryType.categoryType(forIdentifier: .mindfulSession) { types.insert(t) }
        return types
    }

    /// Prompts for read access. Returns false when Health is unavailable or the
    /// request throws; a user who declines still returns true, because
    /// HealthKit deliberately won't tell an app it was denied — you find out by
    /// reading nothing back.
    public func requestAccess() async -> Bool {
        guard Self.isSupported else { return false }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            return true
        } catch {
            return false
        }
    }

    /// True once the user has been through the permission sheet for our types.
    /// HealthKit reports read status as `.notDetermined` until then; it never
    /// reports a denial, so this only tells you whether to prompt.
    public func hasBeenAsked() -> Bool {
        guard Self.isSupported,
              let hrv = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)
        else { return false }
        return store.authorizationStatus(for: hrv) != .notDetermined
    }

    /// Reads one calendar day. Averages the interval samples (HRV, heart rate,
    /// respiration) and sums the cumulative ones (steps, sleep, mindfulness),
    /// which is what each of those means day-over-day.
    public func vitals(for day: Date = .now) async -> DayVitals {
        guard Self.isSupported else { return DayVitals(date: day) }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? day
        let range = HKQuery.predicateForSamples(withStart: start, end: end)

        var result = DayVitals(date: start)
        result.hrvSDNN = await average(.heartRateVariabilitySDNN,
                                       unit: .secondUnit(with: .milli), predicate: range)
        result.restingHeartRate = await average(.restingHeartRate,
                                               unit: HKUnit.count().unitDivided(by: .minute()),
                                               predicate: range)
        result.respiratoryRate = await average(.respiratoryRate,
                                              unit: HKUnit.count().unitDivided(by: .minute()),
                                              predicate: range)
        result.steps = await sum(.stepCount, unit: .count(), predicate: range)
        result.sleepHours = await sleepHours(predicate: range)
        result.mindfulMinutes = await mindfulMinutes(predicate: range)
        return result
    }

    /// The last `days` days, oldest first. Skips days Health knows nothing
    /// about so a sparse history doesn't render as a row of blanks.
    public func recent(days: Int) async -> [DayVitals] {
        var out: [DayVitals] = []
        let calendar = Calendar.current
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: .now) else { continue }
            let vitals = await vitals(for: day)
            if !vitals.isEmpty { out.append(vitals) }
        }
        return out
    }

    // MARK: - Queries

    private func average(_ id: HKQuantityTypeIdentifier, unit: HKUnit,
                         predicate: NSPredicate) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        return await statistic(type, options: .discreteAverage, predicate: predicate) {
            $0.averageQuantity()?.doubleValue(for: unit)
        }
    }

    private func sum(_ id: HKQuantityTypeIdentifier, unit: HKUnit,
                     predicate: NSPredicate) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        return await statistic(type, options: .cumulativeSum, predicate: predicate) {
            $0.sumQuantity()?.doubleValue(for: unit)
        }
    }

    private func statistic(_ type: HKQuantityType, options: HKStatisticsOptions,
                           predicate: NSPredicate,
                           extract: @escaping @Sendable (HKStatistics) -> Double?) async -> Double? {
        await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate,
                                          options: options) { _, stats, _ in
                continuation.resume(returning: stats.flatMap(extract))
            }
            store.execute(query)
        }
    }

    /// Sums only the asleep stages — `.inBed` covers lying awake, which would
    /// overstate how much someone actually slept.
    private func sleepHours(predicate: NSPredicate) async -> Double? {
        guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
        let samples = await categorySamples(type, predicate: predicate)
        guard !samples.isEmpty else { return nil }
        let asleep: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
        ]
        let seconds = samples
            .filter { asleep.contains($0.value) }
            .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
        return seconds > 0 ? seconds / 3600 : nil
    }

    private func mindfulMinutes(predicate: NSPredicate) async -> Double? {
        guard let type = HKCategoryType.categoryType(forIdentifier: .mindfulSession) else { return nil }
        let samples = await categorySamples(type, predicate: predicate)
        guard !samples.isEmpty else { return nil }
        let seconds = samples.reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
        return seconds > 0 ? seconds / 60 : nil
    }

    private func categorySamples(_ type: HKCategoryType,
                                 predicate: NSPredicate) async -> [HKCategorySample] {
        await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                continuation.resume(returning: (samples as? [HKCategorySample]) ?? [])
            }
            store.execute(query)
        }
    }
}
#endif
