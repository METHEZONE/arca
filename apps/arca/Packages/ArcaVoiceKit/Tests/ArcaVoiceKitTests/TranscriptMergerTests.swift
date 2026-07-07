import Testing
import ArcaVoiceKit

@Suite struct TranscriptMergerTests {
    @Test func mergeOrdersTurnsByTimeAndNamesOwner() {
        let mic = [
            SpeakerTurn(speakerKey: "S1", text: "안녕하세요", start: 0.0, end: 1.5, channel: .microphone),
            SpeakerTurn(speakerKey: "S1", text: "네 맞아요", start: 5.0, end: 6.0, channel: .microphone),
        ]
        let system = [
            SpeakerTurn(speakerKey: "S1", text: "반갑습니다", start: 2.0, end: 3.5, channel: .systemAudio),
            SpeakerTurn(speakerKey: "S2", text: "저도요", start: 3.6, end: 4.2, channel: .systemAudio),
        ]

        let merged = TranscriptMerger.merge(
            ownerName: "민성",
            channelTurns: [.microphone: mic, .systemAudio: system]
        )

        #expect(merged.turns.count == 4)
        #expect(merged.turns.map(\.text) == ["안녕하세요", "반갑습니다", "저도요", "네 맞아요"])
        #expect(merged.turns[0].speakerKey == "owner")
        #expect(merged.speakerNames["owner"] == "민성")
        // System-audio labels survive untouched until voice-print matching.
        #expect(merged.turns[1].speakerKey == "S1")
        #expect(merged.turns[2].speakerKey == "S2")
    }
}
