import Foundation
import ArcaVoiceCore

/// Turns raw measurements into the four numbers ARCA shows: sleep quality,
/// stress, readiness for deep work, and — when the user asked for a live
/// measurement — how deep they actually are right now.
///
/// Two rules run through all of it:
///
/// 1. **Missing input means nil, never a default.** A readiness score invented
///    out of no data is worse than an honest "아직 몰라요", because the user
///    would plan their day around it.
/// 2. **Everything is relative to the user's own baseline.** Absolute HRV says
///    almost nothing across people (a 25ms night can be normal for one person
///    and alarming for another); the same person's HRV against their own median
///    says a lot. So baselines need real history before any comparison runs.
public enum VitalsScoring {
    /// Time asleep that counts as a full night. 7.5h — the middle of the adult
    /// range, and what the sleep score is measured against.
    public static let sleepTargetMinutes = 450

    /// Days of history required before a baseline is trusted.
    public static let minimumBaselineSamples = 3

    // MARK: - Sleep

    /// Sleep quality, 0–100, from duration (55), stage architecture (25), and
    /// continuity (20). When the source didn't stage the night, architecture is
    /// dropped and the remaining components are rescaled — an unstaged night
    /// isn't a badly-architected one.
    public static func sleepScore(_ sleep: SleepSummary?,
                                  targetMinutes: Int = sleepTargetMinutes) -> Int? {
        guard let sleep, sleep.asleepMinutes > 0 else { return nil }

        var earned = 0.0
        var possible = 0.0

        let ratio = min(1.0, Double(sleep.asleepMinutes) / Double(max(1, targetMinutes)))
        earned += 55 * ratio
        possible += 55

        if sleep.hasStages {
            let asleep = Double(sleep.asleepMinutes)
            earned += 12.5 * bandScore(Double(sleep.deepMinutes) / asleep, ideal: 0.17, tolerance: 0.07)
            earned += 12.5 * bandScore(Double(sleep.remMinutes) / asleep, ideal: 0.22, tolerance: 0.08)
            possible += 25
        }

        let disruption = Double(sleep.awakeMinutes) * 0.4 + Double(sleep.awakenings) * 1.5
        earned += max(0, 20 - min(20, disruption))
        possible += 20

        return clampScore(earned / possible * 100)
    }

    // MARK: - Stress

    /// Sympathetic load, 0–100 (higher = more stressed), from HRV suppression
    /// against baseline (70%) and resting-heart-rate elevation (30%).
    ///
    /// A day sitting exactly on baseline lands near 30, not 50 — most days are
    /// unremarkable, and a companion that calls every ordinary Tuesday
    /// "moderately stressed" gets ignored.
    public static func stress(hrv: Double?, hrvBaseline: Double?,
                              restingHR: Double?, restingHRBaseline: Double?) -> Int? {
        var parts: [(value: Double, weight: Double)] = []

        if let hrv, let hrvBaseline, hrvBaseline > 0, hrv > 0 {
            let ratio = hrv / hrvBaseline
            parts.append((clamp(100 - 70 * ratio, low: 2, high: 95), 0.7))
        }
        if let restingHR, let restingHRBaseline, restingHRBaseline > 0, restingHR > 0 {
            let delta = restingHR - restingHRBaseline
            parts.append((clamp(30 + delta * 4, low: 2, high: 95), 0.3))
        }

        guard !parts.isEmpty else { return nil }
        let weight = parts.reduce(0) { $0 + $1.weight }
        return clampScore(parts.reduce(0) { $0 + $1.value * $1.weight } / weight)
    }

    // MARK: - Readiness

    /// How ready the body is for deep work, 0–100 — sleep (45), the inverse of
    /// stress (35), HRV against baseline (20), minus a small tax for a hard
    /// session yesterday. Components that are missing drop out and the rest
    /// are rescaled, so a partial picture still produces an honest number.
    public static func readiness(sleepScore: Int?, stress: Int?, hrvRatio: Double?,
                                 yesterdayExerciseMinutes: Int? = nil) -> Int? {
        var parts: [(value: Double, weight: Double)] = []
        if let sleepScore { parts.append((Double(sleepScore), 0.45)) }
        if let stress { parts.append((Double(100 - stress), 0.35)) }
        if let hrvRatio {
            parts.append((clamp((hrvRatio - 0.75) / 0.45 * 100, low: 0, high: 100), 0.20))
        }
        guard !parts.isEmpty else { return nil }

        let weight = parts.reduce(0) { $0 + $1.weight }
        var score = parts.reduce(0) { $0 + $1.value * $1.weight } / weight
        if let minutes = yesterdayExerciseMinutes, minutes > 90 { score -= 5 }
        return clampScore(score)
    }

    // MARK: - Live focus depth

    /// Focus depth from a live measurement, 0–100: heart rate close to resting
    /// (60%) plus beat-to-beat variability (40%). Focused attention shows up as
    /// a calm, *variable* heart — a rate that's both elevated and metronomic is
    /// stress, not flow.
    public static func focusDepth(meanHR: Double, restingHR: Double?,
                                  beatIntervalSD: Double?) -> Int {
        let calm: Double
        if let restingHR, restingHR > 0 {
            calm = clamp(1 - (meanHR - restingHR) / 25, low: 0, high: 1)
        } else {
            // No personal resting rate yet — fall back to a population anchor
            // and let the number firm up once baselines exist.
            calm = clamp(1 - (meanHR - 55) / 40, low: 0, high: 1)
        }
        guard let sd = beatIntervalSD, sd > 0 else { return clampScore(calm * 100) }
        let variability = clamp(sd / 60, low: 0, high: 1)
        return clampScore((calm * 0.6 + variability * 0.4) * 100)
    }

    // MARK: - Baselines

    /// Median of the usable values, or nil until there are enough of them.
    /// Median rather than mean because one sick night shouldn't move a baseline
    /// that everything else is measured against.
    public static func baseline(_ values: [Double],
                                minimumSamples: Int = minimumBaselineSamples) -> Double? {
        let usable = values.filter { $0.isFinite && $0 > 0 }
        guard usable.count >= minimumSamples else { return nil }
        let sorted = usable.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    // MARK: - One-shot evaluation

    /// The single entry point the app uses: today's measurements plus previous
    /// days (ordered oldest → newest, today excluded) produce the full score
    /// set with its explanations.
    public static func evaluate(today: VitalsMetrics,
                                history: [VitalsMetrics],
                                latestDeepMeasure: DeepMeasure? = nil,
                                deepMeasureFreshness: TimeInterval = 90 * 60,
                                now: Date = .now,
                                targetMinutes: Int = sleepTargetMinutes) -> VitalsScores {
        let hrvBaseline = baseline(history.compactMap(\.meanHRV))
        let restingBaseline = baseline(history.compactMap(\.restingHeartRate))

        let sleep = sleepScore(today.sleep, targetMinutes: targetMinutes)
        let todayHRV = today.meanHRV
        let stressScore = stress(hrv: todayHRV, hrvBaseline: hrvBaseline,
                                 restingHR: today.restingHeartRate,
                                 restingHRBaseline: restingBaseline)
        let hrvRatio: Double? = {
            guard let todayHRV, let hrvBaseline, hrvBaseline > 0 else { return nil }
            return todayHRV / hrvBaseline
        }()
        let readinessScore = readiness(sleepScore: sleep, stress: stressScore, hrvRatio: hrvRatio,
                                       yesterdayExerciseMinutes: history.last?.exerciseMinutes)

        var liveFocus: Int?
        if let measure = latestDeepMeasure,
           now.timeIntervalSince(measure.startedAt) <= deepMeasureFreshness,
           now >= measure.startedAt {
            liveFocus = measure.focusDepth
        }

        return VitalsScores(
            readiness: readinessScore,
            stress: stressScore,
            sleep: sleep,
            liveFocus: liveFocus,
            drivers: drivers(today: today, hrvBaseline: hrvBaseline,
                             restingHRBaseline: restingBaseline, targetMinutes: targetMinutes))
    }

    /// Short Korean lines naming what actually moved the numbers, so the score
    /// is never a black box the user has to trust blindly.
    public static func drivers(today: VitalsMetrics,
                               hrvBaseline: Double?,
                               restingHRBaseline: Double?,
                               targetMinutes: Int = sleepTargetMinutes) -> [String] {
        var lines: [String] = []

        if let sleep = today.sleep, sleep.asleepMinutes > 0 {
            let gap = targetMinutes - sleep.asleepMinutes
            if gap >= 30 {
                lines.append(L("수면 \(sleep.durationLabel) — 목표보다 \(VitalsFormat.hoursMinutes(gap)) 짧아요",
                               "Slept \(sleep.durationLabel) — \(VitalsFormat.hoursMinutes(gap)) short of your target"))
            } else if gap <= -30 {
                lines.append(L("수면 \(sleep.durationLabel) — 충분히 잤어요",
                               "Slept \(sleep.durationLabel) — plenty of rest"))
            } else {
                lines.append(L("수면 \(sleep.durationLabel) — 목표에 거의 맞췄어요",
                               "Slept \(sleep.durationLabel) — just about on target"))
            }
            if sleep.hasStages {
                let deepShare = Double(sleep.deepMinutes) / Double(sleep.asleepMinutes)
                if deepShare < 0.10 {
                    lines.append(L("깊은 수면 \(sleep.deepMinutes)분 — 비중이 낮아요 (\(Int(deepShare * 100))%)",
                                   "Deep sleep \(sleep.deepMinutes)m — a small share of the night (\(Int(deepShare * 100))%)"))
                }
            }
            if sleep.awakenings >= 3 {
                lines.append(L("밤중에 \(sleep.awakenings)번 깼어요 — 수면이 끊겼습니다",
                               "Woke \(sleep.awakenings) times — a broken night"))
            }
        } else {
            lines.append(L("어젯밤 수면 기록이 없어요 — 워치를 차고 자면 잡힙니다",
                           "No sleep recorded last night — wear your watch to bed and it'll show up"))
        }

        if let hrv = today.meanHRV {
            if let hrvBaseline, hrvBaseline > 0 {
                let delta = (hrv - hrvBaseline) / hrvBaseline
                let percent = Int(abs(delta) * 100)
                if delta <= -0.15 {
                    lines.append(L("HRV \(Int(hrv))ms — 평소(\(Int(hrvBaseline))ms)보다 \(percent)% 낮아요",
                                   "HRV \(Int(hrv))ms — \(percent)% below your usual \(Int(hrvBaseline))ms"))
                } else if delta >= 0.15 {
                    lines.append(L("HRV \(Int(hrv))ms — 평소보다 \(percent)% 높아요, 회복이 좋습니다",
                                   "HRV \(Int(hrv))ms — \(percent)% above your usual, recovery looks good"))
                } else {
                    lines.append(L("HRV \(Int(hrv))ms — 평소 범위예요",
                                   "HRV \(Int(hrv))ms — right in your usual range"))
                }
            } else {
                lines.append(L("HRV \(Int(hrv))ms — 기준선을 만드는 중이에요 (\(minimumBaselineSamples)일 이상 필요)",
                               "HRV \(Int(hrv))ms — still building your baseline (\(minimumBaselineSamples)+ days needed)"))
            }
        }

        if let resting = today.restingHeartRate, let baseline = restingHRBaseline {
            let delta = resting - baseline
            if delta >= 3 {
                lines.append(L("안정심박 \(Int(resting))bpm — 평소보다 \(Int(delta))bpm 높아요",
                               "Resting heart rate \(Int(resting))bpm — \(Int(delta))bpm above your usual"))
            } else if delta <= -3 {
                lines.append(L("안정심박 \(Int(resting))bpm — 평소보다 낮아요, 좋은 신호입니다",
                               "Resting heart rate \(Int(resting))bpm — below your usual, a good sign"))
            }
        }

        return Array(lines.prefix(4))
    }

    // MARK: - Labels

    public static func readinessLabel(_ score: Int?) -> String {
        guard let score else { return L("측정 대기", "Not measured yet") }
        switch score {
        case 80...: return L("깊게 몰입할 수 있어요", "Ready to go deep")
        case 65..<80: return L("몰입 가능한 상태", "Ready to focus")
        case 50..<65: return L("가벼운 일부터", "Start with something light")
        case 35..<50: return L("회복이 먼저예요", "Recovery comes first")
        default: return L("지금은 쉬어야 해요", "Rest today")
        }
    }

    public static func stressLabel(_ score: Int?) -> String {
        guard let score else { return L("측정 대기", "Not measured yet") }
        switch score {
        case ..<25: return L("아주 안정", "Very calm")
        case 25..<40: return L("안정", "Calm")
        case 40..<55: return L("약간 긴장", "A little tense")
        case 55..<70: return L("긴장 상태", "Tense")
        default: return L("많이 눌려 있어요", "Under a lot of pressure")
        }
    }

    public static func sleepLabel(_ score: Int?) -> String {
        guard let score else { return L("기록 없음", "No record") }
        switch score {
        case 85...: return L("아주 잘 잤어요", "Slept really well")
        case 70..<85: return L("잘 잤어요", "Slept well")
        case 55..<70: return L("보통", "Okay")
        case 40..<55: return L("부족해요", "Not enough")
        default: return L("많이 부족해요", "Far too little")
        }
    }

    public static func focusDepthLabel(_ score: Int?) -> String {
        guard let score else { return L("미측정", "Not measured") }
        switch score {
        case 80...: return L("깊은 몰입", "Deep focus")
        case 65..<80: return L("몰입 중", "In focus")
        case 45..<65: return L("올라오는 중", "Warming up")
        default: return L("아직 얕아요", "Still shallow")
        }
    }

    // MARK: - Helpers

    /// 1.0 inside the ideal band, tapering linearly to 0 at 2.5× the tolerance.
    static func bandScore(_ value: Double, ideal: Double, tolerance: Double) -> Double {
        guard value.isFinite, tolerance > 0 else { return 0 }
        let distance = abs(value - ideal)
        if distance <= tolerance { return 1 }
        return max(0, 1 - (distance - tolerance) / (tolerance * 1.5))
    }

    static func clamp(_ value: Double, low: Double, high: Double) -> Double {
        guard value.isFinite else { return low }
        return min(high, max(low, value))
    }

    static func clampScore(_ value: Double) -> Int {
        Int(clamp(value, low: 0, high: 100).rounded())
    }
}
