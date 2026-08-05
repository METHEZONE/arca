import XCTest
@testable import ArcaVoiceKit

/// The Mac and the iPhone know different halves of a day: only the phone can
/// read HealthKit, only the Mac sees the app-switch timeline the focus profile
/// is built from. So the merge can't be "newer wins" — these tests pin down
/// which side is trusted for what.
final class DailyVitalsMergeTests: XCTestCase {
    private let day = "2026-07-27"
    private let earlier = Date(timeIntervalSince1970: 1_000_000)
    private let later = Date(timeIntervalSince1970: 1_009_000)

    /// The chat block embeds score labels and formatted durations, which follow
    /// the device language, so the language is pinned here rather than left to
    /// whatever the machine running the tests happens to prefer.
    override func setUp() {
        super.setUp()
        ArcaLanguageResolver.apply(.korean)
    }

    override func tearDown() {
        ArcaLanguageResolver.apply(.system)
        super.tearDown()
    }

    func testPhoneMeasurementsSurviveANewerMacWrite() {
        let phone = DailyVitals(
            day: day, updatedAt: earlier, device: "iphone",
            metrics: VitalsMetrics(restingHeartRate: 58,
                                   hrv: [HRVReading(at: earlier, sdnn: 48)],
                                   sleep: SleepSummary(inBedMinutes: 460, asleepMinutes: 440)),
            scores: VitalsScores(readiness: 78, stress: 28, sleep: 88))
        let mac = DailyVitals(day: day, updatedAt: later, device: "mac")

        let merged = mac.merged(with: phone)

        XCTAssertEqual(merged.metrics.restingHeartRate, 58)
        XCTAssertEqual(merged.metrics.hrv.count, 1)
        XCTAssertEqual(merged.scores.readiness, 78)
        XCTAssertEqual(merged.updatedAt, later)
    }

    func testMacFocusProfileSurvivesAPhoneWriteThatHasNone() {
        let mac = DailyVitals(
            day: day, updatedAt: earlier, device: "mac",
            focusWindows: [FocusWindow(hour: 10, score: 1.0, minutesObserved: 240)],
            focusSessions: [FocusSession(startedAt: earlier,
                                         endedAt: earlier.addingTimeInterval(3600),
                                         source: "zone", handledCount: 3)])
        let phone = DailyVitals(day: day, updatedAt: later, device: "iphone",
                                metrics: VitalsMetrics(restingHeartRate: 60))

        let merged = phone.merged(with: mac)

        XCTAssertEqual(merged.focusWindows.count, 1)
        XCTAssertEqual(merged.focusWindows.first?.hour, 10)
        XCTAssertEqual(merged.focusSessions.count, 1)
        XCTAssertEqual(merged.metrics.restingHeartRate, 60)
    }

    /// The whole point of the flag: once the iPhone has written a meal into
    /// Apple Health, no later relay round may reset it and cause a double entry.
    func testHealthWriteFlagIsStickyAcrossMerges() {
        let id = UUID()
        let spokenOnMac = MealEntry(id: id, at: earlier, label: "김치찌개", calories: 520,
                                    writtenToHealth: false, loggedBy: "mac")
        let writtenOnPhone = MealEntry(id: id, at: earlier, label: "김치찌개", calories: 520,
                                       writtenToHealth: true, loggedBy: "mac")

        let mac = DailyVitals(day: day, updatedAt: later, device: "mac", meals: [spokenOnMac])
        let phone = DailyVitals(day: day, updatedAt: earlier, device: "iphone",
                                meals: [writtenOnPhone])

        XCTAssertEqual(mac.merged(with: phone).meals.first?.writtenToHealth, true)
        XCTAssertEqual(phone.merged(with: mac).meals.first?.writtenToHealth, true)
    }

    func testMealsFromBothDevicesAreUnionedInTimeOrder() {
        let mac = DailyVitals(day: day, updatedAt: earlier, device: "mac",
                              meals: [MealEntry(at: later, label: "저녁", calories: 700,
                                                loggedBy: "mac")])
        let phone = DailyVitals(day: day, updatedAt: later, device: "iphone",
                                meals: [MealEntry(at: earlier, label: "점심", calories: 600,
                                                  loggedBy: "iphone")])

        let merged = mac.merged(with: phone)

        XCTAssertEqual(merged.meals.map(\.label), ["점심", "저녁"])
        XCTAssertEqual(merged.loggedCalories, 1300)
    }

    func testDeepMeasuresAreUnionedAndDeduplicatedByStartTime() {
        let measure = DeepMeasure(startedAt: earlier, seconds: 180, meanHR: 58,
                                  minHR: 55, maxHR: 61, focusDepth: 84)
        let a = DailyVitals(day: day, updatedAt: earlier, device: "iphone", deepMeasures: [measure])
        let b = DailyVitals(day: day, updatedAt: later, device: "mac", deepMeasures: [measure])

        XCTAssertEqual(a.merged(with: b).deepMeasures.count, 1)
    }

    func testALiveReadingOnTheOtherDeviceIsNotThrownAway() {
        let phone = DailyVitals(day: day, updatedAt: later, device: "iphone",
                                metrics: VitalsMetrics(restingHeartRate: 58),
                                scores: VitalsScores(readiness: 70))
        let mac = DailyVitals(day: day, updatedAt: earlier, device: "mac",
                              scores: VitalsScores(liveFocus: 91))

        let merged = phone.merged(with: mac)

        XCTAssertEqual(merged.scores.readiness, 70)
        XCTAssertEqual(merged.scores.liveFocus, 91)
    }

    func testRoundTripsThroughJSONUnchanged() throws {
        let original = DailyVitals(
            day: day, updatedAt: earlier, device: "iphone",
            metrics: VitalsMetrics(restingHeartRate: 58,
                                   hrv: [HRVReading(at: earlier, sdnn: 44)],
                                   sleep: SleepSummary(bedtime: earlier, wakeTime: later,
                                                       inBedMinutes: 460, asleepMinutes: 440,
                                                       deepMinutes: 70, remMinutes: 95,
                                                       coreMinutes: 275, awakeMinutes: 12,
                                                       awakenings: 2)),
            scores: VitalsScores(readiness: 76, stress: 31, sleep: 86, drivers: ["수면 7시간 20분"]),
            meals: [MealEntry(at: earlier, label: "점심", calories: 600, loggedBy: "iphone")],
            focusWindows: [FocusWindow(hour: 10, score: 1, minutesObserved: 120)],
            deepMeasures: [DeepMeasure(startedAt: earlier, seconds: 180, meanHR: 58,
                                       minHR: 55, maxHR: 61, focusDepth: 84)],
            focusSessions: [FocusSession(startedAt: earlier, endedAt: later, source: "zone")])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let restored = try decoder.decode(DailyVitals.self, from: encoder.encode(original))

        XCTAssertEqual(restored, original)
    }

    // MARK: - Chat block

    func testChatBlockStaysEmptyWhenNothingHasBeenMeasured() {
        let empty = DailyVitals(day: day, device: "iphone")

        XCTAssertTrue(VitalsPrompt.chatBlock(today: empty, windows: []).isEmpty)
        XCTAssertTrue(VitalsPrompt.chatBlock(today: nil, windows: []).isEmpty)
    }

    func testChatBlockCarriesTheRealFiguresAndForbidsInventingOthers() {
        let today = DailyVitals(
            day: day, device: "iphone",
            metrics: VitalsMetrics(restingHeartRate: 58,
                                   hrv: [HRVReading(at: earlier, sdnn: 44)],
                                   sleep: SleepSummary(inBedMinutes: 460, asleepMinutes: 440)),
            scores: VitalsScores(readiness: 76, stress: 31, sleep: 86))

        let block = VitalsPrompt.chatBlock(today: today, windows: [])

        XCTAssertTrue(block.contains("76/100"))
        XCTAssertTrue(block.contains("31/100"))
        XCTAssertTrue(block.contains("44ms"))
        XCTAssertTrue(block.contains("58bpm"))
        XCTAssertTrue(block.contains("never invent"))
    }
}
