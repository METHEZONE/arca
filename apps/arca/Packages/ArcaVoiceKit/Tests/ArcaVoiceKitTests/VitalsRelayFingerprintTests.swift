import XCTest
@testable import ArcaVoiceKit

/// The fingerprint decides whether a day gets pushed to the relay. Getting it
/// wrong is expensive in both directions: too sensitive and every device spams
/// commits all day, too blunt and the Mac silently shows stale numbers.
final class VitalsRelayFingerprintTests: XCTestCase {
    private let day = "2026-07-27"
    private let at = Date(timeIntervalSince1970: 1_000_000)

    private func sample(steps: Int? = 4_000,
                        activeEnergy: Double? = 300,
                        readiness: Int? = 76,
                        updatedAt: Date? = nil,
                        meals: [MealEntry] = []) -> DailyVitals {
        DailyVitals(
            day: day,
            updatedAt: updatedAt ?? at,
            device: "iphone",
            metrics: VitalsMetrics(restingHeartRate: 58,
                                   hrv: [HRVReading(at: at, sdnn: 44)],
                                   activeEnergyKcal: activeEnergy,
                                   steps: steps),
            scores: VitalsScores(readiness: readiness, stress: 31, sleep: 86),
            meals: meals)
    }

    func testTimestampAloneIsNotAChange() {
        let earlier = sample(updatedAt: at)
        let later = sample(updatedAt: at.addingTimeInterval(3_600))

        XCTAssertEqual(earlier.relayFingerprint, later.relayFingerprint)
    }

    /// The case that motivated the whole design: a ten-minute measurement pass
    /// finds a few hundred more steps and slightly more burned energy. Nobody is
    /// watching those tick on another device, so it must not cost a commit.
    func testCountersTickingUpWithinABucketIsNotAChange() {
        let before = sample(steps: 4_000, activeEnergy: 300)
        let after = sample(steps: 4_180, activeEnergy: 322)

        XCTAssertEqual(before.relayFingerprint, after.relayFingerprint)
    }

    func testCountersCrossingABucketIsAChange() {
        let before = sample(steps: 4_000, activeEnergy: 300)
        let after = sample(steps: 9_000, activeEnergy: 600)

        XCTAssertNotEqual(before.relayFingerprint, after.relayFingerprint)
    }

    func testAScoreMovingIsAlwaysAChange() {
        XCTAssertNotEqual(sample(readiness: 76).relayFingerprint,
                          sample(readiness: 77).relayFingerprint)
    }

    func testAScoreAppearingForTheFirstTimeIsAChange() {
        XCTAssertNotEqual(sample(readiness: nil).relayFingerprint,
                          sample(readiness: 40).relayFingerprint)
    }

    /// The phone flipping this flag is precisely the signal the Mac needs, so it
    /// can never be quantized away — otherwise a meal would be written twice.
    func testMealReachingAppleHealthIsAChange() {
        let id = UUID()
        let pending = MealEntry(id: id, at: at, label: "김치찌개", calories: 520,
                                writtenToHealth: false, loggedBy: "mac")
        let written = MealEntry(id: id, at: at, label: "김치찌개", calories: 520,
                                writtenToHealth: true, loggedBy: "mac")

        XCTAssertNotEqual(sample(meals: [pending]).relayFingerprint,
                          sample(meals: [written]).relayFingerprint)
    }

    func testANewMealIsAChange() {
        XCTAssertNotEqual(sample(meals: []).relayFingerprint,
                          sample(meals: [MealEntry(at: at, label: "점심", calories: 600,
                                                   loggedBy: "iphone")]).relayFingerprint)
    }

    /// Dictionary iteration order must not leak into the fingerprint, or two
    /// devices holding identical days would push each other in a loop forever.
    func testFingerprintIsStableRegardlessOfCollectionOrder() {
        let first = MealEntry(at: at, label: "아침", calories: 300, loggedBy: "iphone")
        let second = MealEntry(at: at.addingTimeInterval(3_600), label: "점심",
                               calories: 600, loggedBy: "iphone")

        XCTAssertEqual(sample(meals: [first, second]).relayFingerprint,
                       sample(meals: [second, first]).relayFingerprint)
    }

    func testFocusProfileChangesAreCarried() {
        var withWindows = sample()
        withWindows.focusWindows = [FocusWindow(hour: 10, score: 1, minutesObserved: 200)]

        XCTAssertNotEqual(sample().relayFingerprint, withWindows.relayFingerprint)
    }
}
