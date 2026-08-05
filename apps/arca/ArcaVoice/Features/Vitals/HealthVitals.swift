#if os(iOS)
import Foundation
import HealthKit
import ArcaVoiceKit

/// ARCA's window into Apple Health. Lives on the iPhone because HealthKit does
/// not exist on macOS — the Mac sees this data only through the relay.
///
/// The read path is deliberately battery-free: everything here is a query
/// against data the Watch already wrote on its own schedule. Nothing in this
/// file starts a sensor. Live measurement is the Watch's on-demand session, and
/// only runs when the user asks for it.
///
/// An `actor` rather than a struct because `HKHealthStore` isn't `Sendable`;
/// keeping the single store instance actor-isolated satisfies strict
/// concurrency without lying about it via `@unchecked`.
actor HealthVitals {
    static let shared = HealthVitals()

    private let store = HKHealthStore()

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: - Types

    /// Everything ARCA reads. Kept explicit so the Health permission sheet
    /// shows the user exactly what it is and nothing more.
    private static var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            HKCategoryType(.sleepAnalysis),
            HKCategoryType(.appleStandHour),
            HKCategoryType(.mindfulSession),
        ]
        // No raw `.heartRate` here on purpose: the phone only needs the daily
        // aggregates, and the live beat-by-beat read belongs to the Watch's
        // own measurement. Asking for less keeps the Health sheet honest.
        let quantities: [HKQuantityTypeIdentifier] = [
            .restingHeartRate, .walkingHeartRateAverage,
            .heartRateVariabilitySDNN, .respiratoryRate,
            .activeEnergyBurned, .basalEnergyBurned,
            .dietaryEnergyConsumed, .dietaryProtein, .dietaryCarbohydrates, .dietaryFatTotal,
            .stepCount, .appleExerciseTime,
        ]
        for identifier in quantities { types.insert(HKQuantityType(identifier)) }
        return types
    }

    /// Everything ARCA writes — food logged by voice, and the mindful minutes a
    /// deep-measure session earns.
    private static var shareTypes: Set<HKSampleType> {
        [
            HKQuantityType(.dietaryEnergyConsumed),
            HKQuantityType(.dietaryProtein),
            HKQuantityType(.dietaryCarbohydrates),
            HKQuantityType(.dietaryFatTotal),
            HKCorrelationType(.food),
            HKCategoryType(.mindfulSession),
        ]
    }

    // MARK: - Authorization

    func requestAuthorization() async throws {
        guard Self.isAvailable else { throw VitalsError.healthUnavailable }
        try await store.requestAuthorization(toShare: Self.shareTypes, read: Self.readTypes)
        UserDefaults.standard.set(true, forKey: "healthAuthorizationRequested")
    }

    /// Whether the Health sheet has ever been shown. HealthKit deliberately
    /// refuses to reveal read permissions (knowing a user declined to share
    /// their heart data is itself a disclosure), so this can only reflect the
    /// write side plus our own flag — never treat it as "reads are allowed".
    func hasRequestedAuthorization() -> Bool {
        guard Self.isAvailable else { return false }
        if UserDefaults.standard.bool(forKey: "healthAuthorizationRequested") { return true }
        return store.authorizationStatus(for: HKQuantityType(.dietaryEnergyConsumed)) != .notDetermined
    }

    func canWriteFood() -> Bool {
        guard Self.isAvailable else { return false }
        return store.authorizationStatus(for: HKQuantityType(.dietaryEnergyConsumed)) == .sharingAuthorized
    }

    // MARK: - Reading

    /// Reads `days` days ending today, keyed by `yyyy-MM-dd`. One pass over each
    /// metric for the whole range rather than a query per day — the difference
    /// is roughly fifteen queries instead of two hundred.
    func history(days: Int, now: Date = .now, calendar: Calendar = .current) async -> [String: VitalsMetrics] {
        guard Self.isAvailable else { return [:] }

        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today) ?? today
        let end = now
        // A night that ended this morning started yesterday evening.
        let sleepWindowStart = calendar.date(byAdding: .day, value: -1, to: start) ?? start

        async let sumsTask = dailySums(from: start, to: end, calendar: calendar)
        async let averagesTask = dailyAverages(from: start, to: end, calendar: calendar)
        async let hrvTask = hrvByDay(from: start, to: end, calendar: calendar)
        async let sleepTask = sleepByDay(from: sleepWindowStart, to: end, calendar: calendar)
        async let standTask = standHoursByDay(from: start, to: end, calendar: calendar)
        async let mindfulTask = mindfulMinutesByDay(from: start, to: end, calendar: calendar)

        let sums = await sumsTask
        let averages = await averagesTask
        let hrv = await hrvTask
        let sleep = await sleepTask
        let stand = await standTask
        let mindful = await mindfulTask

        var result: [String: VitalsMetrics] = [:]

        for offset in 0..<max(1, days) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = VitalsFormat.dayKey(for: date, calendar: calendar)
            let steps = sums[.steps]?[key]
            let exercise = sums[.exercise]?[key]
            result[key] = VitalsMetrics(
                restingHeartRate: averages[.restingHeartRate]?[key],
                walkingHeartRateAverage: averages[.walkingHeartRate]?[key],
                hrv: hrv[key] ?? [],
                respiratoryRate: averages[.respiratoryRate]?[key],
                sleep: sleep[key],
                activeEnergyKcal: sums[.activeEnergy]?[key],
                basalEnergyKcal: sums[.basalEnergy]?[key],
                dietaryEnergyKcal: sums[.dietaryEnergy]?[key],
                proteinGrams: sums[.protein]?[key],
                carbsGrams: sums[.carbs]?[key],
                fatGrams: sums[.fat]?[key],
                steps: steps.map { Int($0.rounded()) },
                exerciseMinutes: exercise.map { Int($0.rounded()) },
                standHours: stand[key],
                mindfulMinutes: mindful[key])
        }
        return result
    }

    // MARK: - Writing

    /// Writes a spoken meal into Apple Health as a food correlation, so the
    /// Health app shows one named entry with its nutrients rather than four
    /// loose numbers.
    func write(meal: MealEntry) async throws {
        guard Self.isAvailable else { throw VitalsError.healthUnavailable }
        guard meal.calories > 0 || meal.proteinGrams != nil
                || meal.carbsGrams != nil || meal.fatGrams != nil else {
            throw VitalsError.nothingToWrite
        }

        var samples: Set<HKSample> = []
        let start = meal.at
        let end = meal.at
        let metadata: [String: Any] = [HKMetadataKeyFoodType: meal.label]

        func add(_ identifier: HKQuantityTypeIdentifier, _ unit: HKUnit, _ value: Double?) {
            guard let value, value > 0 else { return }
            samples.insert(HKQuantitySample(
                type: HKQuantityType(identifier),
                quantity: HKQuantity(unit: unit, doubleValue: value),
                start: start, end: end, metadata: metadata))
        }

        add(.dietaryEnergyConsumed, .kilocalorie(), meal.calories)
        add(.dietaryProtein, .gram(), meal.proteinGrams)
        add(.dietaryCarbohydrates, .gram(), meal.carbsGrams)
        add(.dietaryFatTotal, .gram(), meal.fatGrams)

        guard !samples.isEmpty else { throw VitalsError.nothingToWrite }

        let correlation = HKCorrelation(type: HKCorrelationType(.food),
                                        start: start, end: end,
                                        objects: samples, metadata: metadata)
        try await store.save(correlation)
    }

    /// Records a finished deep-measure session as mindful minutes, so the time
    /// the user spent deliberately focusing shows up in Apple Health too.
    func writeMindfulSession(from start: Date, to end: Date) async throws {
        guard Self.isAvailable, end > start else { return }
        let sample = HKCategorySample(type: HKCategoryType(.mindfulSession),
                                      value: HKCategoryValue.notApplicable.rawValue,
                                      start: start, end: end)
        try await store.save(sample)
    }

    // MARK: - Collectors

    private enum SumMetric: CaseIterable, Sendable {
        case activeEnergy, basalEnergy, dietaryEnergy, protein, carbs, fat, steps, exercise

        var identifier: HKQuantityTypeIdentifier {
            switch self {
            case .activeEnergy: return .activeEnergyBurned
            case .basalEnergy: return .basalEnergyBurned
            case .dietaryEnergy: return .dietaryEnergyConsumed
            case .protein: return .dietaryProtein
            case .carbs: return .dietaryCarbohydrates
            case .fat: return .dietaryFatTotal
            case .steps: return .stepCount
            case .exercise: return .appleExerciseTime
            }
        }

        /// Built inside the task that uses it — `HKUnit` is a non-Sendable class
        /// and must not cross a concurrency boundary.
        var unit: HKUnit {
            switch self {
            case .activeEnergy, .basalEnergy, .dietaryEnergy: return .kilocalorie()
            case .protein, .carbs, .fat: return .gram()
            case .steps: return .count()
            case .exercise: return .minute()
            }
        }
    }

    private enum AverageMetric: CaseIterable, Sendable {
        case restingHeartRate, walkingHeartRate, respiratoryRate

        var identifier: HKQuantityTypeIdentifier {
            switch self {
            case .restingHeartRate: return .restingHeartRate
            case .walkingHeartRate: return .walkingHeartRateAverage
            case .respiratoryRate: return .respiratoryRate
            }
        }

        var unit: HKUnit { .beatsPerMinute }
    }

    private func dailySums(from: Date, to: Date,
                           calendar: Calendar) async -> [SumMetric: [String: Double]] {
        var result: [SumMetric: [String: Double]] = [:]
        await withTaskGroup(of: (SumMetric, [String: Double]).self) { group in
            for metric in SumMetric.allCases {
                group.addTask {
                    let values = await self.dailyStatistics(
                        metric.identifier, unit: metric.unit, options: .cumulativeSum,
                        from: from, to: to, interval: DateComponents(day: 1), calendar: calendar)
                    return (metric, values)
                }
            }
            for await (metric, values) in group { result[metric] = values }
        }
        return result
    }

    private func dailyAverages(from: Date, to: Date,
                               calendar: Calendar) async -> [AverageMetric: [String: Double]] {
        var result: [AverageMetric: [String: Double]] = [:]
        await withTaskGroup(of: (AverageMetric, [String: Double]).self) { group in
            for metric in AverageMetric.allCases {
                group.addTask {
                    let values = await self.dailyStatistics(
                        metric.identifier, unit: metric.unit, options: .discreteAverage,
                        from: from, to: to, interval: DateComponents(day: 1), calendar: calendar)
                    return (metric, values)
                }
            }
            for await (metric, values) in group { result[metric] = values }
        }
        return result
    }

    private func dailyStatistics(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit,
                                 options: HKStatisticsOptions,
                                 from: Date, to: Date, interval: DateComponents,
                                 calendar: Calendar) async -> [String: Double] {
        guard to > from else { return [:] }
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(identifier), predicate: predicate),
            options: options,
            anchorDate: calendar.startOfDay(for: from),
            intervalComponents: interval)
        do {
            let collection = try await descriptor.result(for: store)
            var values: [String: Double] = [:]
            collection.enumerateStatistics(from: from, to: to) { statistics, _ in
                let quantity = options.contains(.cumulativeSum)
                    ? statistics.sumQuantity()
                    : statistics.averageQuantity()
                guard let quantity else { return }
                let key = VitalsFormat.dayKey(for: statistics.startDate, calendar: calendar)
                values[key] = quantity.doubleValue(for: unit)
            }
            return values
        } catch {
            Self.log("\(identifier.rawValue) statistics failed: \(error.localizedDescription)")
            return [:]
        }
    }

    private func hrvByDay(from: Date, to: Date, calendar: Calendar) async -> [String: [HRVReading]] {
        let samples = await quantitySamples(.heartRateVariabilitySDNN, from: from, to: to)
        let unit = HKUnit.secondUnit(with: .milli)
        var result: [String: [HRVReading]] = [:]
        for sample in samples {
            let key = VitalsFormat.dayKey(for: sample.startDate, calendar: calendar)
            result[key, default: []].append(
                HRVReading(at: sample.startDate, sdnn: sample.quantity.doubleValue(for: unit)))
        }
        for key in result.keys {
            result[key]?.sort { $0.at < $1.at }
        }
        return result
    }

    private func standHoursByDay(from: Date, to: Date, calendar: Calendar) async -> [String: Int] {
        let samples = await categorySamples(.appleStandHour, from: from, to: to)
        var result: [String: Int] = [:]
        for sample in samples where sample.value == HKCategoryValueAppleStandHour.stood.rawValue {
            let key = VitalsFormat.dayKey(for: sample.startDate, calendar: calendar)
            result[key, default: 0] += 1
        }
        return result
    }

    private func mindfulMinutesByDay(from: Date, to: Date, calendar: Calendar) async -> [String: Int] {
        let samples = await categorySamples(.mindfulSession, from: from, to: to)
        var seconds: [String: Double] = [:]
        for sample in samples {
            let key = VitalsFormat.dayKey(for: sample.startDate, calendar: calendar)
            seconds[key, default: 0] += sample.endDate.timeIntervalSince(sample.startDate)
        }
        return seconds.mapValues { Int(($0 / 60).rounded()) }
    }

    // MARK: - Sleep

    /// Groups sleep into nights (attributed to the morning the user woke up) and
    /// keeps a single source per night.
    ///
    /// This de-duplication is load-bearing: the iPhone, the Watch, and any
    /// third-party sleep app all write overlapping `sleepAnalysis` samples for
    /// the same night. Summing them naively reports thirteen hours of sleep for
    /// a seven-hour night, which would then poison the sleep score, the
    /// readiness score, and every piece of advice built on top of them.
    private func sleepByDay(from: Date, to: Date, calendar: Calendar) async -> [String: SleepSummary] {
        let samples = await categorySamples(.sleepAnalysis, from: from, to: to)

        var byDayAndSource: [String: [String: [HKCategorySample]]] = [:]
        for sample in samples {
            let key = VitalsFormat.dayKey(for: sample.endDate, calendar: calendar)
            let source = sample.sourceRevision.source.bundleIdentifier
            byDayAndSource[key, default: [:]][source, default: []].append(sample)
        }

        var result: [String: SleepSummary] = [:]
        for (key, bySource) in byDayAndSource {
            let candidates = bySource.values.map(Self.summarize(night:))
            guard let best = candidates.max(by: Self.isLessInformative), best.asleepMinutes > 0 else {
                continue
            }
            result[key] = best
        }
        return result
    }

    /// Ordering for "which source describes this night best": a staged night
    /// beats an unstaged one, and among equals the longer night wins.
    private static func isLessInformative(_ lhs: SleepSummary, _ rhs: SleepSummary) -> Bool {
        if lhs.hasStages != rhs.hasStages { return rhs.hasStages }
        return lhs.asleepMinutes < rhs.asleepMinutes
    }

    private static func summarize(night samples: [HKCategorySample]) -> SleepSummary {
        var summary = SleepSummary()
        var inBedStart: Date?
        var asleepStarts: [Date] = []
        var asleepEnds: [Date] = []

        for sample in samples {
            let minutes = sample.endDate.timeIntervalSince(sample.startDate) / 60
            guard minutes > 0,
                  let value = HKCategoryValueSleepAnalysis(rawValue: sample.value) else { continue }
            let rounded = Int(minutes.rounded())

            switch value {
            case .inBed:
                summary.inBedMinutes += rounded
                inBedStart = min(inBedStart ?? sample.startDate, sample.startDate)
            case .awake:
                summary.awakeMinutes += rounded
                // A few seconds of stirring isn't waking up; two minutes is.
                if minutes >= 2 { summary.awakenings += 1 }
            case .asleepDeep:
                summary.deepMinutes += rounded
                summary.asleepMinutes += rounded
                asleepStarts.append(sample.startDate)
                asleepEnds.append(sample.endDate)
            case .asleepREM:
                summary.remMinutes += rounded
                summary.asleepMinutes += rounded
                asleepStarts.append(sample.startDate)
                asleepEnds.append(sample.endDate)
            case .asleepCore:
                summary.coreMinutes += rounded
                summary.asleepMinutes += rounded
                asleepStarts.append(sample.startDate)
                asleepEnds.append(sample.endDate)
            case .asleepUnspecified:
                summary.asleepMinutes += rounded
                asleepStarts.append(sample.startDate)
                asleepEnds.append(sample.endDate)
            @unknown default:
                continue
            }
        }

        summary.bedtime = inBedStart ?? asleepStarts.min()
        summary.wakeTime = asleepEnds.max()
        if summary.inBedMinutes == 0 {
            summary.inBedMinutes = summary.asleepMinutes + summary.awakeMinutes
        }
        return summary
    }

    // MARK: - Query plumbing

    private func quantitySamples(_ identifier: HKQuantityTypeIdentifier,
                                 from: Date, to: Date) async -> [HKQuantitySample] {
        guard to > from else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(identifier), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\HKQuantitySample.startDate)],
            limit: HKObjectQueryNoLimit)
        do {
            return try await descriptor.result(for: store)
        } catch {
            Self.log("\(identifier.rawValue) samples failed: \(error.localizedDescription)")
            return []
        }
    }

    private func categorySamples(_ identifier: HKCategoryTypeIdentifier,
                                 from: Date, to: Date) async -> [HKCategorySample] {
        guard to > from else { return [] }
        // No strict options here: a sleep sample that begins before the window
        // still describes the night we're asking about.
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(identifier), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\HKCategorySample.startDate)],
            limit: HKObjectQueryNoLimit)
        do {
            return try await descriptor.result(for: store)
        } catch {
            Self.log("\(identifier.rawValue) samples failed: \(error.localizedDescription)")
            return []
        }
    }

    private static func log(_ message: String) {
        NSLog("[ARCA vitals] %@", message)
    }
}

private extension HKUnit {
    static var beatsPerMinute: HKUnit { .count().unitDivided(by: .minute()) }
}
#endif
