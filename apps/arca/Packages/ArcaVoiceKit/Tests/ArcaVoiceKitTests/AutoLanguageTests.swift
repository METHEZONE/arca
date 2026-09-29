import Foundation
import Testing
@testable import Transcribe
import ArcaVoiceCore

struct AutoLanguageTests {
    private func seg(_ text: String, end: TimeInterval, conf: Double?, volatile: Bool = false) -> LiveSegment {
        LiveSegment(channel: .microphone, text: text, start: max(0, end - 2), end: end, isVolatile: volatile, confidence: conf)
    }

    @Test func holdsFinalsUntilWindowThenPicksTheMoreConfident() {
        let race = AutoLanguageTranscriber.Race(count: 2)
        guard case .hold = race.offer(seg("hello", end: 5, conf: 0.3), from: 0, window: 20) else { Issue.record("expected hold"); return }
        guard case .hold = race.offer(seg("안녕하세요", end: 6, conf: 0.9), from: 1, window: 20) else { Issue.record("expected hold"); return }
        guard case .decided(let winner, let held) = race.offer(seg("회의 시작", end: 21, conf: 0.9), from: 1, window: 20) else {
            Issue.record("expected decision"); return
        }
        #expect(winner == 1)
        #expect(held.map(\.text) == ["안녕하세요"])   // the trigger is yielded by its own task
        guard case .drop = race.offer(seg("x", end: 25, conf: 0.9), from: 0, window: 20) else { Issue.record("loser should drop"); return }
        guard case .show = race.offer(seg("y", end: 26, conf: 0.9), from: 1, window: 20) else { Issue.record("winner should show"); return }
    }

    @Test func shortRecordingDecidesAtTheEndAndFlushes() {
        let race = AutoLanguageTranscriber.Race(count: 2)
        _ = race.offer(seg("hi", end: 3, conf: 0.8), from: 0, window: 20)
        _ = race.offer(seg("하이", end: 3, conf: 0.4), from: 1, window: 20)
        let first = race.end(1)
        #expect(first.decided == nil && first.finish == false)
        let last = race.end(0)
        #expect(last.decided == 0)
        #expect(last.flush.map(\.text) == ["hi"])
        #expect(last.finish)
    }

    @Test func tieGoesToTheFirstCandidate() {
        let race = AutoLanguageTranscriber.Race(count: 2)
        _ = race.offer(seg("a", end: 3, conf: 0.7), from: 0, window: 20)
        _ = race.offer(seg("b", end: 3, conf: 0.72), from: 1, window: 20)
        _ = race.end(0)
        #expect(race.end(1).decided == 0)
    }
}
