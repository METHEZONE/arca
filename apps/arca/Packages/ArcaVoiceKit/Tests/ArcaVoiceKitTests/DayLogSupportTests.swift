import XCTest
@testable import ArcaVoiceKit

final class DayLogSupportTests: XCTestCase {
    func testTimelineCoalescesConsecutiveSameAppEntries() {
        let base = Date(timeIntervalSince1970: 1_800)
        let first = DayLogTimelineEntry(timestamp: base, bundleId: "com.apple.Terminal", appName: "Terminal")
        let duplicate = DayLogTimelineEntry(timestamp: base.addingTimeInterval(30),
                                            bundleId: "com.apple.Terminal",
                                            appName: "Terminal")
        let next = DayLogTimelineEntry(timestamp: base.addingTimeInterval(60),
                                       bundleId: "com.apple.dt.Xcode",
                                       appName: "Xcode")

        let entries = DayLogTimeline.appending(next, to:
            DayLogTimeline.appending(duplicate, to:
                DayLogTimeline.appending(first, to: [])))

        XCTAssertEqual(entries, [first, next])
    }

    func testTimelineSummariesUseDurationsBetweenSwitches() {
        let base = Date(timeIntervalSince1970: 3_600)
        let entries = [
            DayLogTimelineEntry(timestamp: base, bundleId: "a", appName: "A"),
            DayLogTimelineEntry(timestamp: base.addingTimeInterval(120), bundleId: "b", appName: "B"),
            DayLogTimelineEntry(timestamp: base.addingTimeInterval(300), bundleId: "a", appName: "A"),
        ]

        let summaries = DayLogTimeline.summaries(from: entries, until: base.addingTimeInterval(360))

        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(Set(summaries.map(\.bundleId)), Set(["a", "b"]))
        XCTAssertEqual(Int(summaries.first(where: { $0.bundleId == "b" })?.seconds ?? 0), 180)
        XCTAssertEqual(Int(summaries.first(where: { $0.bundleId == "a" })?.seconds ?? 0), 180)
    }

    func testEvenTimeSnapshotSamplingSelection() {
        let sample = DayLogSnapshotSampler.evenlySampled(Array(0..<20), limit: 5)

        XCTAssertEqual(sample, [0, 5, 10, 14, 19])
    }

    func testDigestDayGuardHonorsEnabledHourAndLastDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = DateComponents(calendar: calendar, timeZone: calendar.timeZone,
                                  year: 2026, month: 7, day: 9, hour: 21, minute: 5).date!

        XCTAssertFalse(DayDigestGuard.shouldGenerateDigest(now: date,
                                                           enabled: false,
                                                           digestHour: 21,
                                                           lastDigestDay: nil,
                                                           calendar: calendar))
        XCTAssertFalse(DayDigestGuard.shouldGenerateDigest(now: date.addingTimeInterval(-3600),
                                                           enabled: true,
                                                           digestHour: 21,
                                                           lastDigestDay: nil,
                                                           calendar: calendar))
        XCTAssertFalse(DayDigestGuard.shouldGenerateDigest(now: date,
                                                           enabled: true,
                                                           digestHour: 21,
                                                           lastDigestDay: "2026-07-09",
                                                           calendar: calendar))
        XCTAssertTrue(DayDigestGuard.shouldGenerateDigest(now: date,
                                                          enabled: true,
                                                          digestHour: 21,
                                                          lastDigestDay: "2026-07-08",
                                                          calendar: calendar))
    }
}
