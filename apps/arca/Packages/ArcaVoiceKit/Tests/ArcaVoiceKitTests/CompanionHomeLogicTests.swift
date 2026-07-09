import Testing
import Foundation
import ArcaVoiceKit

@Suite("Companion home logic")
struct CompanionHomeLogicTests {
    @Test func derivesConversationTitleFromFirstUserText() {
        #expect(CompanionHomeLogic.conversationTitle(
            firstUserText: "  오늘 회의 정리하고 다음 액션 뽑아줘  ",
            fallbackText: "fallback",
            maxCharacters: 10
        ) == "오늘 회의 정리하…")
    }

    @Test func fallsBackForEmptyConversationTitle() {
        #expect(CompanionHomeLogic.conversationTitle(
            firstUserText: " ",
            fallbackText: nil
        ) == "새 대화")
    }

    @Test func dayCountIsInclusive() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = DateComponents(calendar: calendar, year: 2026, month: 7, day: 1, hour: 23).date!
        let now = DateComponents(calendar: calendar, year: 2026, month: 7, day: 3, hour: 1).date!
        #expect(CompanionHomeLogic.dayCount(since: start, now: now, calendar: calendar) == 3)
    }

    @Test func dailyCacheKeyUsesCalendarDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        let date = DateComponents(calendar: calendar, year: 2026, month: 7, day: 9, hour: 22).date!
        #expect(CompanionHomeLogic.dailyCacheKey(prefix: "arca.remark", date: date, calendar: calendar) == "arca.remark.2026-07-09")
    }
}
