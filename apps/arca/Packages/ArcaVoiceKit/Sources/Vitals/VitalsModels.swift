import Foundation
import ArcaVoiceCore

/// One heart-rate-variability reading — SDNN in milliseconds, the metric
/// Apple Watch writes. Higher is generally calmer/more recovered.
public struct HRVReading: Codable, Equatable, Sendable, Identifiable {
    public var id: Date { at }
    public var at: Date
    public var sdnn: Double

    public init(at: Date, sdnn: Double) {
        self.at = at
        self.sdnn = sdnn
    }
}

/// Last night's sleep as HealthKit describes it. Stage minutes are zero when
/// the source couldn't stage the night (iPhone-only sleep, older watches) —
/// that's a real distinction, so scoring drops the architecture component
/// rather than pretending the stages were all "core".
public struct SleepSummary: Codable, Equatable, Sendable {
    public var bedtime: Date?
    public var wakeTime: Date?
    public var inBedMinutes: Int
    public var asleepMinutes: Int
    public var deepMinutes: Int
    public var remMinutes: Int
    public var coreMinutes: Int
    public var awakeMinutes: Int
    /// Separate awakenings recorded during the night.
    public var awakenings: Int

    public init(bedtime: Date? = nil, wakeTime: Date? = nil,
                inBedMinutes: Int = 0, asleepMinutes: Int = 0,
                deepMinutes: Int = 0, remMinutes: Int = 0, coreMinutes: Int = 0,
                awakeMinutes: Int = 0, awakenings: Int = 0) {
        self.bedtime = bedtime
        self.wakeTime = wakeTime
        self.inBedMinutes = inBedMinutes
        self.asleepMinutes = asleepMinutes
        self.deepMinutes = deepMinutes
        self.remMinutes = remMinutes
        self.coreMinutes = coreMinutes
        self.awakeMinutes = awakeMinutes
        self.awakenings = awakenings
    }

    /// True when the source broke the night into stages.
    public var hasStages: Bool { deepMinutes + remMinutes + coreMinutes > 0 }

    public var durationLabel: String {
        VitalsFormat.hoursMinutes(asleepMinutes)
    }
}

/// The day's measurements, as read from HealthKit. Every field is optional
/// because "not measured" and "measured as zero" are different facts.
public struct VitalsMetrics: Codable, Equatable, Sendable {
    public var restingHeartRate: Double?
    public var walkingHeartRateAverage: Double?
    public var hrv: [HRVReading]
    public var respiratoryRate: Double?
    public var sleep: SleepSummary?
    public var activeEnergyKcal: Double?
    public var basalEnergyKcal: Double?
    public var dietaryEnergyKcal: Double?
    public var proteinGrams: Double?
    public var carbsGrams: Double?
    public var fatGrams: Double?
    public var steps: Int?
    public var exerciseMinutes: Int?
    public var standHours: Int?
    public var mindfulMinutes: Int?

    public init(restingHeartRate: Double? = nil,
                walkingHeartRateAverage: Double? = nil,
                hrv: [HRVReading] = [],
                respiratoryRate: Double? = nil,
                sleep: SleepSummary? = nil,
                activeEnergyKcal: Double? = nil,
                basalEnergyKcal: Double? = nil,
                dietaryEnergyKcal: Double? = nil,
                proteinGrams: Double? = nil,
                carbsGrams: Double? = nil,
                fatGrams: Double? = nil,
                steps: Int? = nil,
                exerciseMinutes: Int? = nil,
                standHours: Int? = nil,
                mindfulMinutes: Int? = nil) {
        self.restingHeartRate = restingHeartRate
        self.walkingHeartRateAverage = walkingHeartRateAverage
        self.hrv = hrv
        self.respiratoryRate = respiratoryRate
        self.sleep = sleep
        self.activeEnergyKcal = activeEnergyKcal
        self.basalEnergyKcal = basalEnergyKcal
        self.dietaryEnergyKcal = dietaryEnergyKcal
        self.proteinGrams = proteinGrams
        self.carbsGrams = carbsGrams
        self.fatGrams = fatGrams
        self.steps = steps
        self.exerciseMinutes = exerciseMinutes
        self.standHours = standHours
        self.mindfulMinutes = mindfulMinutes
    }

    /// The most recent HRV reading of the day.
    public var latestHRV: HRVReading? {
        hrv.max { $0.at < $1.at }
    }

    /// Mean of the day's HRV readings (nil when none were recorded).
    public var meanHRV: Double? {
        guard !hrv.isEmpty else { return nil }
        return hrv.reduce(0) { $0 + $1.sdnn } / Double(hrv.count)
    }

    /// Total energy burned, when both halves are known.
    public var totalEnergyKcal: Double? {
        guard activeEnergyKcal != nil || basalEnergyKcal != nil else { return nil }
        return (activeEnergyKcal ?? 0) + (basalEnergyKcal ?? 0)
    }

    /// How much of this snapshot actually carries measurements. Used to decide
    /// which device's copy of a day wins a merge — the phone reads HealthKit,
    /// the Mac cannot, so the phone's copy is always the richer one.
    public var richness: Int {
        var count = 0
        if restingHeartRate != nil { count += 1 }
        if walkingHeartRateAverage != nil { count += 1 }
        if !hrv.isEmpty { count += 1 }
        if respiratoryRate != nil { count += 1 }
        if sleep != nil { count += 1 }
        if activeEnergyKcal != nil { count += 1 }
        if basalEnergyKcal != nil { count += 1 }
        if dietaryEnergyKcal != nil { count += 1 }
        if steps != nil { count += 1 }
        if exerciseMinutes != nil { count += 1 }
        if standHours != nil { count += 1 }
        if mindfulMinutes != nil { count += 1 }
        return count
    }

    public var isEmpty: Bool { richness == 0 }
}

/// The derived numbers ARCA actually shows. Each is nil when its inputs were
/// missing — a companion that invents a readiness score is worse than one that
/// says it doesn't know yet.
public struct VitalsScores: Codable, Equatable, Sendable {
    /// 0–100. How ready the body is for deep work.
    public var readiness: Int?
    /// 0–100, higher = more sympathetic load.
    public var stress: Int?
    /// 0–100 sleep quality for last night.
    public var sleep: Int?
    /// 0–100 depth from the most recent deep measure, when it's recent enough
    /// to still describe "right now".
    public var liveFocus: Int?
    /// Short Korean lines explaining what moved the numbers.
    public var drivers: [String]

    public init(readiness: Int? = nil, stress: Int? = nil, sleep: Int? = nil,
                liveFocus: Int? = nil, drivers: [String] = []) {
        self.readiness = readiness
        self.stress = stress
        self.sleep = sleep
        self.liveFocus = liveFocus
        self.drivers = drivers
    }

    public var isEmpty: Bool {
        readiness == nil && stress == nil && sleep == nil && liveFocus == nil
    }

    /// Fills this snapshot's gaps from another (used when merging two devices'
    /// views of the same day).
    public func filling(from other: VitalsScores) -> VitalsScores {
        VitalsScores(
            readiness: readiness ?? other.readiness,
            stress: stress ?? other.stress,
            sleep: sleep ?? other.sleep,
            liveFocus: liveFocus ?? other.liveFocus,
            drivers: drivers.isEmpty ? other.drivers : drivers)
    }
}

/// One hour of the day, and how strongly the user focuses in it. `score` is
/// relative to the user's own best hour (1.0 = their peak), so it answers
/// "when am I sharpest" rather than pretending to an absolute scale.
public struct FocusWindow: Codable, Equatable, Sendable, Identifiable {
    public var id: Int { hour }
    /// Local hour, 0–23.
    public var hour: Int
    /// 0–1, normalized against the user's strongest hour.
    public var score: Double
    /// How much observed focus time this bucket is based on.
    public var minutesObserved: Int

    public init(hour: Int, score: Double, minutesObserved: Int) {
        self.hour = hour
        self.score = score
        self.minutesObserved = minutesObserved
    }

    public var label: String {
        String(format: "%02d:00–%02d:00", hour, (hour + 1) % 24)
    }
}

/// A stretch of focused work ARCA observed. The chronotype profile is built
/// from these, so they're the evidence trail behind "you focus best at 10am".
public struct FocusSession: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date
    /// "zone" (ZONE mode), "daylog" (uninterrupted app stretch), "deepmeasure".
    public var source: String
    /// Interruptions ARCA absorbed on the user's behalf during the session.
    public var handledCount: Int
    /// Items that still needed the user — the human-bottleneck count.
    public var interruptedCount: Int

    public init(id: UUID = UUID(), startedAt: Date, endedAt: Date, source: String,
                handledCount: Int = 0, interruptedCount: Int = 0) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.source = source
        self.handledCount = handledCount
        self.interruptedCount = interruptedCount
    }

    public var minutes: Int {
        max(0, Int(endedAt.timeIntervalSince(startedAt) / 60))
    }

    /// 0–1. A session ARCA fully shielded scores 1; every item that broke
    /// through pulls it down.
    public var quality: Double {
        guard interruptedCount > 0 else { return 1.0 }
        return max(0.2, 1.0 - Double(interruptedCount) * 0.15)
    }
}

/// The result of an on-demand measurement on the Watch. Nothing here is
/// sampled unless the user asks for it — the always-on path is battery-free.
public struct DeepMeasure: Codable, Equatable, Sendable, Identifiable {
    public var id: Date { startedAt }
    public var startedAt: Date
    public var seconds: Int
    public var meanHR: Double
    public var minHR: Double
    public var maxHR: Double
    /// SDNN in ms, if the Watch wrote one inside the measurement window.
    public var hrvSDNN: Double?
    /// Standard deviation of beat-to-beat intervals derived from the heart-rate
    /// stream, in ms. A proxy — the Watch doesn't expose raw RR intervals to
    /// third-party apps outside an ECG, so this is labelled as an estimate
    /// everywhere it's shown.
    public var beatIntervalSD: Double?
    /// 0–100 focus depth computed from the above.
    public var focusDepth: Int

    public init(startedAt: Date, seconds: Int, meanHR: Double, minHR: Double, maxHR: Double,
                hrvSDNN: Double? = nil, beatIntervalSD: Double? = nil, focusDepth: Int) {
        self.startedAt = startedAt
        self.seconds = seconds
        self.meanHR = meanHR
        self.minHR = minHR
        self.maxHR = maxHR
        self.hrvSDNN = hrvSDNN
        self.beatIntervalSD = beatIntervalSD
        self.focusDepth = focusDepth
    }
}

/// One meal, logged by voice. Calories go to Apple Health from the iPhone;
/// a meal logged on the Mac rides the relay and the phone writes it there.
public struct MealEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var at: Date
    public var label: String
    public var calories: Double
    public var proteinGrams: Double?
    public var carbsGrams: Double?
    public var fatGrams: Double?
    public var note: String?
    /// Set once the entry exists in HealthKit, so no device writes it twice.
    public var writtenToHealth: Bool
    /// "mac" | "iphone" — where it was spoken.
    public var loggedBy: String

    public init(id: UUID = UUID(), at: Date, label: String, calories: Double,
                proteinGrams: Double? = nil, carbsGrams: Double? = nil, fatGrams: Double? = nil,
                note: String? = nil, writtenToHealth: Bool = false, loggedBy: String) {
        self.id = id
        self.at = at
        self.label = label
        self.calories = calories
        self.proteinGrams = proteinGrams
        self.carbsGrams = carbsGrams
        self.fatGrams = fatGrams
        self.note = note
        self.writtenToHealth = writtenToHealth
        self.loggedBy = loggedBy
    }
}

/// Everything ARCA knows about one day of the user's body and focus. This is
/// both the on-disk record and the relay wire format — one file per day under
/// `vitals/YYYY-MM-DD.json`.
public struct DailyVitals: Codable, Equatable, Sendable, Identifiable {
    public var id: String { day }
    /// `yyyy-MM-dd` in the user's local calendar.
    public var day: String
    public var updatedAt: Date
    /// "mac" | "iphone" — which device last wrote this copy.
    public var device: String
    public var metrics: VitalsMetrics
    public var scores: VitalsScores
    public var meals: [MealEntry]
    public var focusWindows: [FocusWindow]
    public var deepMeasures: [DeepMeasure]
    public var focusSessions: [FocusSession]

    public init(day: String, updatedAt: Date = .now, device: String,
                metrics: VitalsMetrics = VitalsMetrics(),
                scores: VitalsScores = VitalsScores(),
                meals: [MealEntry] = [],
                focusWindows: [FocusWindow] = [],
                deepMeasures: [DeepMeasure] = [],
                focusSessions: [FocusSession] = []) {
        self.day = day
        self.updatedAt = updatedAt
        self.device = device
        self.metrics = metrics
        self.scores = scores
        self.meals = meals
        self.focusWindows = focusWindows
        self.deepMeasures = deepMeasures
        self.focusSessions = focusSessions
    }

    /// Calories eaten today from ARCA's own meal log (the phone also reads the
    /// HealthKit total, which includes meals logged in other apps).
    public var loggedCalories: Double {
        meals.reduce(0) { $0 + $1.calories }
    }

    public var pendingHealthWrites: [MealEntry] {
        meals.filter { !$0.writtenToHealth }
    }

    /// A fingerprint of everything *another device* actually reads off this day.
    ///
    /// Deliberately not a hash of the whole document. Active energy and step
    /// count climb all day, so hashing the file would make every ten-minute
    /// measurement pass look like a change and push a fresh commit to the relay —
    /// well over a hundred a day, per device, for numbers nobody is watching tick.
    /// The continuously-climbing counters are quantized here so a push happens
    /// when the figure visibly moves, and `updatedAt` is excluded entirely
    /// because it changes even when nothing else did.
    public var relayFingerprint: String {
        func bucket(_ value: Double?, _ size: Double) -> Int {
            guard let value, value > 0, size > 0 else { return 0 }
            return Int((value / size).rounded(.down))
        }

        var parts: [String] = [day]
        parts.append("r\(scores.readiness ?? -1)/s\(scores.stress ?? -1)"
                     + "/z\(scores.sleep ?? -1)/l\(scores.liveFocus ?? -1)")
        parts.append(scores.drivers.joined(separator: "|"))
        if let sleep = metrics.sleep {
            parts.append("sleep\(sleep.asleepMinutes)/\(sleep.deepMinutes)"
                         + "/\(sleep.remMinutes)/\(sleep.awakeMinutes)/\(sleep.awakenings)")
        }
        parts.append("hrv\(bucket(metrics.meanHRV, 1))")
        parts.append("rhr\(bucket(metrics.restingHeartRate, 1))")
        parts.append("whr\(bucket(metrics.walkingHeartRateAverage, 1))")
        parts.append("rr\(bucket(metrics.respiratoryRate, 1))")
        parts.append("active\(bucket(metrics.activeEnergyKcal, 50))")
        parts.append("basal\(bucket(metrics.basalEnergyKcal, 100))")
        parts.append("diet\(bucket(metrics.dietaryEnergyKcal, 50))")
        parts.append("steps\(bucket(metrics.steps.map(Double.init), 500))")
        parts.append("ex\(bucket(metrics.exerciseMinutes.map(Double.init), 5))")
        parts.append("stand\(metrics.standHours ?? -1)/mind\(metrics.mindfulMinutes ?? -1)")
        parts.append("meals" + meals
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { "\($0.id.uuidString.prefix(8))\(Int($0.calories))\($0.writtenToHealth ? "H" : "-")" }
            .joined())
        parts.append("windows" + focusWindows
            .sorted { $0.hour < $1.hour }
            .map { "\($0.hour):\(Int($0.score * 100)):\($0.minutesObserved)" }
            .joined(separator: ","))
        parts.append("measures" + deepMeasures
            .sorted { $0.startedAt < $1.startedAt }
            .map { "\(Int($0.startedAt.timeIntervalSince1970)):\($0.focusDepth)" }
            .joined(separator: ","))
        parts.append("sessions" + focusSessions
            .sorted { $0.startedAt < $1.startedAt }
            .map { "\($0.id.uuidString.prefix(8)):\($0.minutes):\($0.interruptedCount)" }
            .joined(separator: ","))
        return parts.joined(separator: ";")
    }

    /// Deterministically combines two devices' views of the same day.
    ///
    /// The rules exist because the two sides know different things: only the
    /// iPhone can read HealthKit, and only the Mac sees the app-switch
    /// timeline that the focus profile is built from. So neither side is
    /// simply "newer wins" — each field group goes to whoever actually knows.
    public func merged(with other: DailyVitals) -> DailyVitals {
        precondition(day == other.day, "merging different days")

        // Metrics: whoever measured more. Ties break on recency.
        let mineWinsMetrics: Bool = {
            if metrics.richness != other.metrics.richness {
                return metrics.richness > other.metrics.richness
            }
            return updatedAt >= other.updatedAt
        }()
        let winningMetrics = mineWinsMetrics ? metrics : other.metrics
        // Scores derive from metrics, so they follow the metrics, then borrow
        // anything the loser knew and the winner didn't (e.g. a live focus
        // reading that landed on the other device).
        let winningScores = (mineWinsMetrics ? scores : other.scores)
            .filling(from: mineWinsMetrics ? other.scores : scores)

        // Meals: union by id. A copy already in HealthKit wins so the flag
        // never regresses and the phone can't double-write.
        var mealsByID: [UUID: MealEntry] = [:]
        for meal in meals + other.meals {
            if let existing = mealsByID[meal.id] {
                if existing.writtenToHealth { continue }
                mealsByID[meal.id] = meal.writtenToHealth ? meal : existing
            } else {
                mealsByID[meal.id] = meal
            }
        }

        var sessionsByID: [UUID: FocusSession] = [:]
        for session in focusSessions + other.focusSessions {
            sessionsByID[session.id] = session
        }

        var measuresByStart: [Date: DeepMeasure] = [:]
        for measure in deepMeasures + other.deepMeasures {
            measuresByStart[measure.startedAt] = measure
        }

        // Focus windows: whoever observed more focus time. The Mac normally
        // wins this because the app-switch timeline lives there.
        let myObserved = focusWindows.reduce(0) { $0 + $1.minutesObserved }
        let theirObserved = other.focusWindows.reduce(0) { $0 + $1.minutesObserved }
        let winningWindows = myObserved >= theirObserved ? focusWindows : other.focusWindows

        return DailyVitals(
            day: day,
            updatedAt: max(updatedAt, other.updatedAt),
            device: updatedAt >= other.updatedAt ? device : other.device,
            metrics: winningMetrics,
            scores: winningScores,
            meals: mealsByID.values.sorted { $0.at < $1.at },
            focusWindows: winningWindows.sorted { $0.hour < $1.hour },
            deepMeasures: measuresByStart.values.sorted { $0.startedAt < $1.startedAt },
            focusSessions: sessionsByID.values.sorted { $0.startedAt < $1.startedAt })
    }
}

/// Shared formatting so the same duration never renders two ways.
public enum VitalsFormat {
    public static func hoursMinutes(_ minutes: Int) -> String {
        guard minutes > 0 else { return "—" }
        let hours = minutes / 60
        let mins = minutes % 60
        if hours == 0 { return L("\(mins)분", "\(mins)m") }
        if mins == 0 { return L("\(hours)시간", "\(hours)h") }
        return L("\(hours)시간 \(mins)분", "\(hours)h \(mins)m")
    }

    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public static func date(fromDayKey key: String, calendar: Calendar = .current) -> Date? {
        let pieces = key.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: pieces[0], month: pieces[1], day: pieces[2]))
    }
}
