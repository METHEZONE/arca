import XCTest
@testable import ArcaVoiceKit

/// The ledger is what the product claims it did for you, so its arithmetic has to
/// be right and its silences have to be deliberate.
final class FocusLedgerTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        DateComponents(calendar: calendar, timeZone: calendar.timeZone,
                       year: 2026, month: 7, day: day, hour: hour, minute: minute).date!
    }

    private func vitalsDay(_ day: Int, sessions: [FocusSession]) -> DailyVitals {
        DailyVitals(day: String(format: "2026-07-%02d", day),
                    updatedAt: date(day: day, hour: 23),
                    device: "mac",
                    focusSessions: sessions)
    }

    private func session(day: Int, startHour: Int, minutes: Int,
                         absorbed: Int, escalated: Int) -> FocusSession {
        FocusSession(startedAt: date(day: day, hour: startHour),
                     endedAt: date(day: day, hour: startHour, minute: minutes),
                     source: "zone",
                     handledCount: absorbed,
                     interruptedCount: escalated)
    }

    // MARK: - Totals

    func testSumsFocusTimeAndBothSidesOfTheInterruptionCount() {
        let days = [
            vitalsDay(20, sessions: [session(day: 20, startHour: 10, minutes: 50, absorbed: 4, escalated: 1)]),
            vitalsDay(21, sessions: [
                session(day: 21, startHour: 9, minutes: 40, absorbed: 3, escalated: 0),
                session(day: 21, startHour: 14, minutes: 30, absorbed: 2, escalated: 2),
            ]),
        ]

        let ledger = FocusLedgerBuilder.build(days: days, loopsClosed: 6)

        XCTAssertEqual(ledger.zoneMinutes, 120)
        XCTAssertEqual(ledger.sessionCount, 3)
        XCTAssertEqual(ledger.absorbed, 9)
        XCTAssertEqual(ledger.escalated, 3)
        XCTAssertEqual(ledger.loopsClosed, 6)
        XCTAssertEqual(ledger.averageSessionMinutes, 40)
    }

    func testNamesTheBestDay() {
        let days = [
            vitalsDay(20, sessions: [session(day: 20, startHour: 10, minutes: 30, absorbed: 0, escalated: 0)]),
            vitalsDay(21, sessions: [session(day: 21, startHour: 10, minutes: 95, absorbed: 0, escalated: 0)]),
            vitalsDay(22, sessions: [session(day: 22, startHour: 10, minutes: 45, absorbed: 0, escalated: 0)]),
        ]

        let best = FocusLedgerBuilder.build(days: days).bestDay

        XCTAssertEqual(best?.day, "2026-07-21")
        XCTAssertEqual(best?.minutes, 95)
    }

    /// Deterministic on a tie, and specifically the more recent day — a
    /// personal best you set yesterday is more motivating than the same number
    /// from last week.
    func testBestDayBreaksTiesTowardTheMoreRecentDay() {
        let days = [
            vitalsDay(21, sessions: [session(day: 21, startHour: 10, minutes: 60, absorbed: 0, escalated: 0)]),
            vitalsDay(20, sessions: [session(day: 20, startHour: 10, minutes: 60, absorbed: 0, escalated: 0)]),
        ]

        XCTAssertEqual(FocusLedgerBuilder.build(days: days).bestDay?.day, "2026-07-21")
        // And it does not depend on the order the days arrive in.
        XCTAssertEqual(FocusLedgerBuilder.build(days: days.reversed()).bestDay?.day, "2026-07-21")
    }

    // MARK: - Honest silences

    func testEmptyWhenNothingHasHappened() {
        let ledger = FocusLedgerBuilder.build(days: [vitalsDay(20, sessions: [])])

        XCTAssertTrue(ledger.isEmpty)
        XCTAssertNil(ledger.bestDay)
        XCTAssertNil(ledger.averageSessionMinutes)
    }

    /// A shield with nothing to block hasn't earned a percentage.
    func testNoAbsorbRateWhenNothingCameIn() {
        let ledger = FocusLedgerBuilder.build(days: [
            vitalsDay(20, sessions: [session(day: 20, startHour: 10, minutes: 50, absorbed: 0, escalated: 0)]),
        ])

        XCTAssertNil(ledger.absorbRate)
        XCTAssertEqual(ledger.zoneMinutes, 50)
    }

    func testAbsorbRateIsTheShareArcaKeptOffTheDesk() {
        let ledger = FocusLedgerBuilder.build(days: [
            vitalsDay(20, sessions: [session(day: 20, startHour: 10, minutes: 50, absorbed: 9, escalated: 1)]),
        ])

        XCTAssertEqual(ledger.absorbRate ?? 0, 0.9, accuracy: 0.001)
    }

    func testClosedLoopsCountEvenWithNoFocusSessions() {
        let ledger = FocusLedgerBuilder.build(days: [vitalsDay(20, sessions: [])], loopsClosed: 4)

        XCTAssertFalse(ledger.isEmpty)
        XCTAssertEqual(ledger.loopsClosed, 4)
        XCTAssertEqual(ledger.zoneMinutes, 0)
    }

    // MARK: - Trend

    func testTrendSplitsTheRunIntoThisWeekAndLastWeek() {
        // 14 days, 30 minutes a day for the first week, 60 for the second.
        let days = (1...14).map { index in
            vitalsDay(index, sessions: [
                session(day: index, startHour: 10, minutes: index <= 7 ? 30 : 60,
                        absorbed: 1, escalated: 0),
            ])
        }

        let trend = FocusLedgerBuilder.trend(days: days, window: 7)

        XCTAssertEqual(trend.previous.zoneMinutes, 210)
        XCTAssertEqual(trend.current.zoneMinutes, 420)
        XCTAssertEqual(trend.minutesDelta, 210)
        XCTAssertEqual(trend.minutesDeltaPercent, 100)
        XCTAssertTrue(trend.isImproving)
        XCTAssertTrue(trend.hasComparison)
    }

    /// "Up ∞% from zero" is not information, so there's no percentage to show.
    func testNoPercentageWhenThereWasNoPreviousWeek() {
        let days = (1...5).map { index in
            vitalsDay(index, sessions: [
                session(day: index, startHour: 10, minutes: 40, absorbed: 0, escalated: 0),
            ])
        }

        let trend = FocusLedgerBuilder.trend(days: days, window: 7)

        XCTAssertNil(trend.minutesDeltaPercent)
        XCTAssertFalse(trend.hasComparison)
        XCTAssertEqual(trend.current.zoneMinutes, 200)
    }

    func testTrendHandlesFewerDaysThanAWindowWithoutOverlap() {
        let days = (1...9).map { index in
            vitalsDay(index, sessions: [
                session(day: index, startHour: 10, minutes: 10, absorbed: 0, escalated: 0),
            ])
        }

        let trend = FocusLedgerBuilder.trend(days: days, window: 7)

        // 7 most recent in current, the remaining 2 in previous — never double-counted.
        XCTAssertEqual(trend.current.zoneMinutes, 70)
        XCTAssertEqual(trend.previous.zoneMinutes, 20)
    }
}
