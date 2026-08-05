import XCTest
@testable import ArcaVoiceKit

final class VitalsScoringTests: XCTestCase {

    /// The driver lines are user-facing copy that follows the device language, so
    /// the language is pinned here rather than left to whatever the machine
    /// running the tests happens to prefer.
    override func setUp() {
        super.setUp()
        ArcaLanguageResolver.apply(.korean)
    }

    override func tearDown() {
        ArcaLanguageResolver.apply(.system)
        super.tearDown()
    }

    // MARK: - Sleep

    func testSleepScoreRewardsAFullWellArchitectedNight() {
        let night = SleepSummary(inBedMinutes: 470, asleepMinutes: 455,
                                 deepMinutes: 78, remMinutes: 100, coreMinutes: 277,
                                 awakeMinutes: 8, awakenings: 1)

        let score = VitalsScoring.sleepScore(night)

        XCTAssertNotNil(score)
        XCTAssertGreaterThanOrEqual(score ?? 0, 90)
    }

    func testSleepScoreDropsForAShortBrokenNight() {
        let night = SleepSummary(inBedMinutes: 300, asleepMinutes: 250,
                                 deepMinutes: 20, remMinutes: 30, coreMinutes: 200,
                                 awakeMinutes: 40, awakenings: 6)

        let score = VitalsScoring.sleepScore(night)

        XCTAssertNotNil(score)
        XCTAssertLessThan(score ?? 100, 55)
    }

    /// A night the watch couldn't stage is not a badly-architected night. The
    /// architecture component drops out and the remainder is rescaled, so an
    /// unstaged night lands next to a well-staged one — never down with a night
    /// that genuinely had almost no deep or REM sleep.
    func testUnstagedNightIsScoredAsUnknownNotAsBadlyArchitected() {
        let unstaged = SleepSummary(inBedMinutes: 470, asleepMinutes: 455,
                                    awakeMinutes: 8, awakenings: 1)
        let wellStaged = SleepSummary(inBedMinutes: 470, asleepMinutes: 455,
                                      deepMinutes: 77, remMinutes: 100, coreMinutes: 278,
                                      awakeMinutes: 8, awakenings: 1)
        let barelyAnyDeepSleep = SleepSummary(inBedMinutes: 470, asleepMinutes: 455,
                                              deepMinutes: 10, remMinutes: 10, coreMinutes: 435,
                                              awakeMinutes: 8, awakenings: 1)

        let unstagedScore = VitalsScoring.sleepScore(unstaged) ?? 0
        let wellStagedScore = VitalsScoring.sleepScore(wellStaged) ?? 0
        let poorScore = VitalsScoring.sleepScore(barelyAnyDeepSleep) ?? 0

        XCTAssertEqual(unstagedScore, wellStagedScore, accuracy: 2)
        XCTAssertGreaterThan(unstagedScore - poorScore, 15)
    }

    func testSleepScoreIsNilWithoutAMeasuredNight() {
        XCTAssertNil(VitalsScoring.sleepScore(nil))
        XCTAssertNil(VitalsScoring.sleepScore(SleepSummary(inBedMinutes: 60, asleepMinutes: 0)))
    }

    // MARK: - Stress

    func testStressNeedsABaselineBeforeItSaysAnything() {
        XCTAssertNil(VitalsScoring.stress(hrv: 40, hrvBaseline: nil,
                                          restingHR: 60, restingHRBaseline: nil))
    }

    func testSuppressedHRVReadsAsMoreStressThanBaseline() {
        let onBaseline = VitalsScoring.stress(hrv: 50, hrvBaseline: 50,
                                              restingHR: 58, restingHRBaseline: 58)
        let suppressed = VitalsScoring.stress(hrv: 32, hrvBaseline: 50,
                                              restingHR: 65, restingHRBaseline: 58)

        XCTAssertNotNil(onBaseline)
        XCTAssertNotNil(suppressed)
        XCTAssertGreaterThan(suppressed ?? 0, onBaseline ?? 100)
    }

    /// An ordinary day sitting exactly on baseline should not be described as
    /// half-stressed — otherwise every unremarkable Tuesday reads as a warning.
    func testAnOrdinaryDayDoesNotReadAsStressed() {
        let score = VitalsScoring.stress(hrv: 50, hrvBaseline: 50,
                                         restingHR: 58, restingHRBaseline: 58)

        XCTAssertEqual(score ?? -1, 30, accuracy: 2)
    }

    // MARK: - Readiness

    func testReadinessRescalesWhenComponentsAreMissing() {
        let sleepOnly = VitalsScoring.readiness(sleepScore: 80, stress: nil, hrvRatio: nil)

        XCTAssertEqual(sleepOnly, 80)
    }

    func testReadinessIsNilWhenNothingIsKnown() {
        XCTAssertNil(VitalsScoring.readiness(sleepScore: nil, stress: nil, hrvRatio: nil))
    }

    func testHardSessionYesterdayCostsReadinessToday() {
        let rested = VitalsScoring.readiness(sleepScore: 80, stress: 30, hrvRatio: 1.0,
                                             yesterdayExerciseMinutes: 20)
        let hammered = VitalsScoring.readiness(sleepScore: 80, stress: 30, hrvRatio: 1.0,
                                               yesterdayExerciseMinutes: 140)

        XCTAssertEqual((rested ?? 0) - (hammered ?? 0), 5)
    }

    // MARK: - Baselines

    func testBaselineIsTheMedianAndIgnoresJunk() {
        XCTAssertEqual(VitalsScoring.baseline([40, 50, 60]), 50)
        XCTAssertEqual(VitalsScoring.baseline([40, 50, 60, 70]), 55)
        XCTAssertEqual(VitalsScoring.baseline([0, -3, 40, 50, 60]), 50)
    }

    func testBaselineWithholdsItselfUntilThereIsEnoughHistory() {
        XCTAssertNil(VitalsScoring.baseline([50, 52]))
        XCTAssertNotNil(VitalsScoring.baseline([50, 52, 54]))
    }

    // MARK: - Focus depth

    func testCalmVariableHeartReadsDeeperThanElevatedSteadyHeart() {
        let deep = VitalsScoring.focusDepth(meanHR: 58, restingHR: 56, beatIntervalSD: 55)
        let strained = VitalsScoring.focusDepth(meanHR: 84, restingHR: 56, beatIntervalSD: 12)

        XCTAssertGreaterThan(deep, strained)
        XCTAssertGreaterThanOrEqual(deep, 80)
    }

    func testFocusDepthStillWorksWithoutAVariabilityProxy() {
        let score = VitalsScoring.focusDepth(meanHR: 58, restingHR: 56, beatIntervalSD: nil)

        XCTAssertGreaterThan(score, 80)
    }

    // MARK: - Whole-day evaluation

    func testEvaluateProducesNilScoresWhenThereIsNothingToScoreYet() {
        let scores = VitalsScoring.evaluate(today: VitalsMetrics(), history: [])

        XCTAssertNil(scores.readiness)
        XCTAssertNil(scores.stress)
        XCTAssertNil(scores.sleep)
        XCTAssertFalse(scores.drivers.isEmpty, "the user should still be told why there's no score")
    }

    func testEvaluateUsesHistoryForBaselinesAndExplainsItself() {
        let history = (0..<5).map { index in
            VitalsMetrics(restingHeartRate: 58,
                          hrv: [HRVReading(at: Date(timeIntervalSince1970: Double(index) * 86_400),
                                           sdnn: 52)],
                          exerciseMinutes: 20)
        }
        let today = VitalsMetrics(
            restingHeartRate: 64,
            hrv: [HRVReading(at: Date(timeIntervalSince1970: 500_000), sdnn: 34)],
            sleep: SleepSummary(inBedMinutes: 360, asleepMinutes: 330,
                                deepMinutes: 40, remMinutes: 60, coreMinutes: 230,
                                awakeMinutes: 20, awakenings: 3))

        let scores = VitalsScoring.evaluate(today: today, history: history)

        XCTAssertNotNil(scores.readiness)
        XCTAssertNotNil(scores.stress)
        XCTAssertNotNil(scores.sleep)
        XCTAssertTrue(scores.drivers.contains { $0.contains("HRV") })
        XCTAssertTrue(scores.drivers.contains { $0.contains("수면") })
    }

    func testStaleDeepMeasureDoesNotClaimToDescribeRightNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let stale = DeepMeasure(startedAt: now.addingTimeInterval(-4 * 3600), seconds: 180,
                               meanHR: 58, minHR: 55, maxHR: 62, focusDepth: 88)
        let fresh = DeepMeasure(startedAt: now.addingTimeInterval(-10 * 60), seconds: 180,
                                meanHR: 58, minHR: 55, maxHR: 62, focusDepth: 88)

        XCTAssertNil(VitalsScoring.evaluate(today: VitalsMetrics(), history: [],
                                            latestDeepMeasure: stale, now: now).liveFocus)
        XCTAssertEqual(VitalsScoring.evaluate(today: VitalsMetrics(), history: [],
                                              latestDeepMeasure: fresh, now: now).liveFocus, 88)
    }
}
