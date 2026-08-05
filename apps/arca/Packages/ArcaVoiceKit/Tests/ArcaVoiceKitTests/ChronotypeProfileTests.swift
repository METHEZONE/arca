import XCTest
@testable import ArcaVoiceKit
// The hour-slicing helper is internal to Vitals — reach it directly rather than
// widening the public surface just to test it.
@testable import Vitals

final class ChronotypeProfileTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        DateComponents(calendar: calendar, timeZone: calendar.timeZone,
                       year: 2026, month: 7, day: day, hour: hour, minute: minute).date!
    }

    /// The narrative and the bucket labels are user-facing copy that follows the
    /// device language, so the language is pinned here rather than left to
    /// whatever the machine running the tests happens to prefer.
    override func setUp() {
        super.setUp()
        ArcaLanguageResolver.apply(.korean)
    }

    override func tearDown() {
        ArcaLanguageResolver.apply(.system)
        super.tearDown()
    }

    // MARK: - Bucketing

    func testAStretchIsSplitAcrossTheHoursItActuallySpans() {
        let evidence = FocusEvidence(startedAt: date(day: 1, hour: 10, minute: 40),
                                     minutes: 90, quality: 1, source: "test")

        let slices = ChronotypeProfile.hourSlices(of: evidence, calendar: calendar)

        XCTAssertEqual(slices.map(\.hour), [10, 11, 12])
        XCTAssertEqual(slices[0].minutes, 20, accuracy: 0.01)
        XCTAssertEqual(slices[1].minutes, 60, accuracy: 0.01)
        XCTAssertEqual(slices[2].minutes, 10, accuracy: 0.01)
    }

    func testProfileWithholdsItselfUntilThereIsEnoughEvidence() {
        let thin = [FocusEvidence(startedAt: date(day: 1, hour: 10), minutes: 60,
                                  quality: 1, source: "test")]

        XCTAssertTrue(ChronotypeProfile.windows(from: thin, calendar: calendar).isEmpty)
    }

    func testPeakHourNormalizesToOneAndWeakHoursFallBelow() {
        // Four mornings of solid 10am work, plus a short distracted 3pm each day.
        var evidence: [FocusEvidence] = []
        for day in 1...4 {
            evidence.append(FocusEvidence(startedAt: date(day: day, hour: 10),
                                          minutes: 55, quality: 1, source: "zone"))
            evidence.append(FocusEvidence(startedAt: date(day: day, hour: 15),
                                          minutes: 14, quality: 0.4, source: "daylog"))
        }

        let windows = ChronotypeProfile.windows(from: evidence, calendar: calendar)
        let tenAM = windows.first { $0.hour == 10 }
        let threePM = windows.first { $0.hour == 15 }

        XCTAssertEqual(tenAM?.score ?? 0, 1.0, accuracy: 0.001)
        XCTAssertNotNil(threePM)
        XCTAssertLessThan(threePM?.score ?? 1, 0.3)
        XCTAssertEqual(ChronotypeProfile.best(windows, count: 1).first?.hour, 10)
    }

    func testNarrativeMergesAdjacentPeakHoursIntoOneRange() {
        var evidence: [FocusEvidence] = []
        for day in 1...4 {
            evidence.append(FocusEvidence(startedAt: date(day: day, hour: 10),
                                          minutes: 60, quality: 1, source: "zone"))
            evidence.append(FocusEvidence(startedAt: date(day: day, hour: 11),
                                          minutes: 60, quality: 1, source: "zone"))
        }
        let windows = ChronotypeProfile.windows(from: evidence, calendar: calendar)

        let narrative = ChronotypeProfile.narrative(windows)

        XCTAssertEqual(narrative, "오전 10시–정오에 가장 깊게 몰입해요.")
    }

    func testNarrativeSaysSoWhenItDoesNotKnow() {
        XCTAssertEqual(ChronotypeProfile.narrative([]), "아직 몰입 패턴을 만들 데이터가 부족해요.")
    }

    func testNextWindowLooksForwardAndWrapsToTomorrow() {
        let windows = [
            FocusWindow(hour: 10, score: 1.0, minutesObserved: 200),
            FocusWindow(hour: 21, score: 0.2, minutesObserved: 200),
        ]

        XCTAssertEqual(ChronotypeProfile.nextWindow(after: date(day: 1, hour: 8),
                                                    windows: windows, calendar: calendar)?.hour, 10)
        // Past the only strong hour — the answer is tomorrow's, not nil.
        XCTAssertEqual(ChronotypeProfile.nextWindow(after: date(day: 1, hour: 18),
                                                    windows: windows, calendar: calendar)?.hour, 10)
    }

    // MARK: - Evidence from the Mac's app timeline

    func testTimelineEvidenceSkipsShortStretchesAndNonFocusApps() {
        let entries = [
            // 40 minutes in Xcode — real focus.
            DayLogTimelineEntry(timestamp: date(day: 1, hour: 9), bundleId: "com.apple.dt.Xcode", appName: "Xcode"),
            // 5 minutes in Slack — too short and not focus anyway.
            DayLogTimelineEntry(timestamp: date(day: 1, hour: 9, minute: 40),
                                bundleId: "com.tinyspeck.slackmacgap", appName: "Slack"),
            // 50 minutes in Slack — long, but still not deep work.
            DayLogTimelineEntry(timestamp: date(day: 1, hour: 9, minute: 45),
                                bundleId: "com.tinyspeck.slackmacgap", appName: "Slack"),
            DayLogTimelineEntry(timestamp: date(day: 1, hour: 10, minute: 35),
                                bundleId: "com.apple.dt.Xcode", appName: "Xcode"),
        ]

        let evidence = ChronotypeProfile.evidence(fromTimeline: entries,
                                                  until: date(day: 1, hour: 11))

        XCTAssertEqual(evidence.count, 2)
        XCTAssertTrue(evidence.allSatisfy { $0.source == "daylog" })
        XCTAssertEqual(evidence[0].minutes, 40, accuracy: 0.01)
        XCTAssertEqual(evidence[1].minutes, 25, accuracy: 0.01)
    }

    /// An app left open while the user is away must not be credited as an
    /// eight-hour flow state.
    func testAbandonedMachineIsTruncatedNotCelebrated() {
        let entries = [
            DayLogTimelineEntry(timestamp: date(day: 1, hour: 9),
                                bundleId: "com.apple.dt.Xcode", appName: "Xcode"),
        ]

        let evidence = ChronotypeProfile.evidence(fromTimeline: entries,
                                                  until: date(day: 1, hour: 20))

        XCTAssertEqual(evidence.count, 1)
        XCTAssertEqual(evidence[0].minutes, 75, accuracy: 0.01)
    }

    func testZoneSessionsLoseQualityForEveryInterruptionThatBrokeThrough() {
        let clean = FocusSession(startedAt: date(day: 1, hour: 10),
                                 endedAt: date(day: 1, hour: 11), source: "zone",
                                 handledCount: 4, interruptedCount: 0)
        let broken = FocusSession(startedAt: date(day: 2, hour: 10),
                                  endedAt: date(day: 2, hour: 11), source: "zone",
                                  handledCount: 1, interruptedCount: 3)

        let evidence = ChronotypeProfile.evidence(fromSessions: [clean, broken])

        XCTAssertEqual(evidence.count, 2)
        XCTAssertEqual(evidence[0].quality, 1.0, accuracy: 0.001)
        XCTAssertEqual(evidence[1].quality, 0.55, accuracy: 0.001)
    }

    // MARK: - Reconciling to the four onboarding buckets

    func testMorningPeakReportsBackAsTheMorningBucket() {
        let windows = [
            FocusWindow(hour: 9, score: 1.0, minutesObserved: 200),
            FocusWindow(hour: 10, score: 0.9, minutesObserved: 180),
            FocusWindow(hour: 15, score: 0.2, minutesObserved: 60),
        ]

        XCTAssertEqual(ChronotypeProfile.dominantBucket(windows), .morning)
    }

    func testLateNightPeakReportsBackAsTheNightBucket() {
        let windows = [
            FocusWindow(hour: 22, score: 1.0, minutesObserved: 240),
            FocusWindow(hour: 23, score: 0.95, minutesObserved: 200),
        ]

        XCTAssertEqual(ChronotypeProfile.dominantBucket(windows), .night)
    }

    /// A day with no owner is genuinely irregular — and "불규칙" is one of the four
    /// answers the user was offered, so it's a real result rather than a fallback.
    func testASpreadOutDayReportsBackAsIrregular() {
        let windows = [
            FocusWindow(hour: 9, score: 1.0, minutesObserved: 120),
            FocusWindow(hour: 14, score: 1.0, minutesObserved: 120),
            FocusWindow(hour: 22, score: 1.0, minutesObserved: 120),
        ]

        XCTAssertEqual(ChronotypeProfile.dominantBucket(windows), .wild)
    }

    func testNoBucketIsClaimedWithoutAProfile() {
        XCTAssertNil(ChronotypeProfile.dominantBucket([]))
        // Present but too thinly observed to name a chronotype.
        XCTAssertNil(ChronotypeProfile.dominantBucket([
            FocusWindow(hour: 9, score: 1.0, minutesObserved: 10),
        ]))
    }

    func testBucketLabelsMatchTheOnboardingVocabulary() {
        XCTAssertEqual(ChronotypeProfile.FocusBucket.morning.label, "아침 — 세상이 조용할 때")
        XCTAssertEqual(ChronotypeProfile.FocusBucket.afternoon.label, "오후 — 엔진이 데워진 뒤")
        XCTAssertEqual(ChronotypeProfile.FocusBucket.night.label, "밤 — 방해가 사라진 뒤")
        XCTAssertEqual(ChronotypeProfile.FocusBucket.wild.label, "불규칙 — 몰입이 오면 그때")
    }

    func testMomentaryFocusSessionsAreIgnored() {
        let blip = FocusSession(startedAt: date(day: 1, hour: 10),
                                endedAt: date(day: 1, hour: 10, minute: 2), source: "zone")

        XCTAssertTrue(ChronotypeProfile.evidence(fromSessions: [blip]).isEmpty)
    }
}
