import Foundation
import Testing
@testable import ArcaVoiceKit

@Suite struct ParticipantsWorkflowTests {
    @Test func overlapScoringPicksLargestOverlap() {
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        let sessionStart = base.addingTimeInterval(60)
        let sessionEnd = base.addingTimeInterval(60 * 61)
        let weak = CalendarEventInfo(
            title: "Earlier standup",
            start: base,
            end: base.addingTimeInterval(60 * 20)
        )
        let winner = CalendarEventInfo(
            title: "Roadmap call",
            start: base.addingTimeInterval(60 * 10),
            end: base.addingTimeInterval(60 * 70)
        )
        let outside = CalendarEventInfo(
            title: "Later",
            start: base.addingTimeInterval(60 * 90),
            end: base.addingTimeInterval(60 * 120)
        )

        let best = CalendarOverlapScorer.bestEvent(
            overlapping: [weak, outside, winner],
            start: sessionStart,
            end: sessionEnd
        )

        #expect(best?.title == "Roadmap call")
    }

    @Test func summaryLoopReturnsPerRecipientResults() async {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "blocked" }
        }

        let sender = ComposioEmailSender(sendHandler: { recipient, _, _ in
            if recipient == "fail@example.com" { throw Boom() }
        })
        let notes = MeetingNotes(title: "Demo", summaryMarkdown: "요약")

        let results = await sender.sendSummary(
            to: [" ok@example.com ", "fail@example.com", "OK@example.com", ""],
            sessionTitle: "Fallback",
            notes: notes,
            date: Date(timeIntervalSinceReferenceDate: 0)
        )

        #expect(results.map { $0.recipient } == ["ok@example.com", "fail@example.com"])
        #expect(results[0].success)
        #expect(results[1].success == false)
        #expect(results[1].errorDescription == "blocked")
    }
}
