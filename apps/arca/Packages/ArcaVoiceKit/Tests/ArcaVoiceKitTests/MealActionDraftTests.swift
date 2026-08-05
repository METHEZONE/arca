import XCTest
@testable import ArcaVoiceKit

/// Voice meal logging goes straight into Apple Health with no confirmation step,
/// so the tag parser is the only thing standing between a mumbled sentence and a
/// wrong entry in someone's health record.
final class MealActionDraftTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private var now: Date {
        DateComponents(calendar: calendar, timeZone: calendar.timeZone,
                       year: 2026, month: 7, day: 27, hour: 20, minute: 15).date!
    }

    // MARK: - Parsing out of a reply

    func testParsesAMealTagFromTheEndOfAReply() {
        let reply = """
        김치찌개 한 그릇이면 대략 520kcal로 봤어요.
        [MEAL: {"label":"김치찌개","calories":520,"proteinGrams":22,"carbsGrams":48,"fatGrams":24}]
        """

        let draft = ClaudeChat.mealDraft(in: reply)

        XCTAssertEqual(draft?.label, "김치찌개")
        XCTAssertEqual(draft?.calories, 520)
        XCTAssertEqual(draft?.proteinGrams, 22)
        XCTAssertEqual(draft?.fatGrams, 24)
    }

    func testParsesAMinimalTagWithNoMacros() {
        let reply = #"프로틴 셰이크 기록했어요. [MEAL: {"label":"protein shake","calories":180}]"#

        let draft = ClaudeChat.mealDraft(in: reply)

        XCTAssertEqual(draft?.label, "protein shake")
        XCTAssertEqual(draft?.calories, 180)
        XCTAssertNil(draft?.proteinGrams)
    }

    func testIgnoresRepliesWithNoMealTag() {
        XCTAssertNil(ClaudeChat.mealDraft(in: "오늘 뭐 드셨어요?"))
    }

    /// A tag with nothing worth recording must be dropped rather than written as
    /// a zero-calorie entry.
    func testRejectsATagWithNothingToRecord() {
        XCTAssertNil(ClaudeChat.mealDraft(in: #"[MEAL: {"label":"물","calories":0}]"#))
        XCTAssertNil(ClaudeChat.mealDraft(in: #"[MEAL: {"label":"","calories":500}]"#))
    }

    func testTheTagNeverReachesTheUsersScreen() {
        let reply = #"김치찌개 520kcal로 기록했어요. [MEAL: {"label":"김치찌개","calories":520}]"#

        let visible = ClaudeChat.stripActionTags(reply)

        XCTAssertEqual(visible, "김치찌개 520kcal로 기록했어요.")
        XCTAssertFalse(visible.contains("MEAL"))
    }

    func testStrippingLeavesOtherActionTagsHandledToo() {
        let reply = """
        보냈어요.
        [EMAIL: {"to":"a@b.com","subject":"s","body":"b"}]
        [MEAL: {"label":"샐러드","calories":220}]
        """

        let visible = ClaudeChat.stripActionTags(reply)

        XCTAssertEqual(visible, "보냈어요.")
    }

    // MARK: - Timing

    func testAbsentTimestampMeansNow() {
        let draft = MealActionDraft(label: "간식", calories: 100)

        XCTAssertEqual(draft.date(now: now, calendar: calendar), now)
    }

    func testBareTimeIsInterpretedAsTodayAtThatTime() {
        let draft = MealActionDraft(label: "점심", calories: 600, at: "12:30")

        let resolved = draft.date(now: now, calendar: calendar)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: resolved)

        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 7)
        XCTAssertEqual(parts.day, 27)
        XCTAssertEqual(parts.hour, 12)
        XCTAssertEqual(parts.minute, 30)
    }

    func testFullTimestampIsHonoured() {
        let draft = MealActionDraft(label: "저녁", calories: 700, at: "2026-07-26T19:00")

        let parts = calendar.dateComponents([.day, .hour],
                                            from: draft.date(now: now, calendar: calendar))

        XCTAssertEqual(parts.day, 26)
        XCTAssertEqual(parts.hour, 19)
    }

    /// A timestamp the model garbled should log the meal at the current time,
    /// not throw the entry away and not land it in 1970.
    func testUnparseableTimestampFallsBackToNow() {
        let draft = MealActionDraft(label: "점심", calories: 600, at: "아까")

        XCTAssertEqual(draft.date(now: now, calendar: calendar), now)
    }
}
