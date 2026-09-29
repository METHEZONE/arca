import Testing
import Foundation
@testable import Intelligence
@testable import ArcaVoiceKit

@Suite struct SpeakerAttributionTests {
    private typealias Answer = ClaudeSpeakerAttributor.Answer

    private func answer(_ speakers: [(String, String, Bool)], _ lines: String) -> Answer {
        Answer(speakers: speakers.map { Answer.Speaker(id: $0.0, name: $0.1, isOwner: $0.2) },
               lineSpeakers: lines.map(String.init))
    }

    @Test func oneLabelPerLine() throws {
        let labels = try ClaudeSpeakerAttributor.resolve(
            answer([("A", "", true), ("B", "김대표", false)], "AABA"),
            lineCount: 4, ownerName: "민성", korean: true)
        #expect(labels == ["민성", "민성", "김대표", "민성"])
    }

    @Test func unnamedPeopleAreNumberedInOrderOfSpeaking() throws {
        let labels = try ClaudeSpeakerAttributor.resolve(
            answer([("A", "", false), ("B", "", false), ("C", "", true)], "BCABC"),
            lineCount: 5, ownerName: "Min", korean: false)
        #expect(labels == ["Speaker 1", "Min", "Speaker 2", "Speaker 1", "Min"])
    }

    @Test func onlyOneSpeakerCanBeTheOwner() throws {
        let labels = try ClaudeSpeakerAttributor.resolve(
            answer([("A", "", true), ("B", "", true)], "AB"),
            lineCount: 2, ownerName: "민성", korean: true)
        #expect(labels == ["민성", "화자 1"])
    }

    @Test func aShortListIsPaddedFromTheLastLine() throws {
        let labels = try ClaudeSpeakerAttributor.resolve(
            answer([("A", "", true), ("B", "", false)], "AAAABBBBB"),
            lineCount: 10, ownerName: "민성", korean: true)
        #expect(labels.count == 10)
        #expect(labels[9] == "화자 1")
    }

    @Test func aLongListIsTrimmed() throws {
        let labels = try ClaudeSpeakerAttributor.resolve(
            answer([("A", "", true), ("B", "", false)], "ABAB"),
            lineCount: 3, ownerName: "민성", korean: true)
        #expect(labels == ["민성", "화자 1", "민성"])
    }

    @Test func aMostlyEmptyAnswerIsRejected() {
        #expect(throws: SpeakerAttributionError.self) {
            try ClaudeSpeakerAttributor.resolve(
                answer([("A", "", true)], "AAA"),
                lineCount: 10, ownerName: "민성", korean: true)
        }
    }

    @Test func unknownIdsCountAsUnplaced() throws {
        let labels = try ClaudeSpeakerAttributor.resolve(
            answer([("A", "", true), ("B", "", false)], "ABABABABAZ"),
            lineCount: 10, ownerName: "민성", korean: true)
        #expect(labels[9] == "민성", "an unknown id inherits the line before")
    }

    /// Seen from the production proxy: "Unknown" where an empty string was asked for.
    @Test func placeholderNamesBecomeNumberedSpeakers() throws {
        let labels = try ClaudeSpeakerAttributor.resolve(
            answer([("A", "Unknown", false), ("B", "", true), ("C", "Speaker 2", false), ("D", "김대표", false)], "ABCD"),
            lineCount: 4, ownerName: "민성", korean: true)
        #expect(labels == ["화자 1", "민성", "화자 2", "김대표"])
    }

    @Test func theOwnerNameIsNeverGivenToSomeoneElse() throws {
        let labels = try ClaudeSpeakerAttributor.resolve(
            answer([("A", "민성", false), ("B", "", true)], "AB"),
            lineCount: 2, ownerName: "민성", korean: true)
        #expect(labels == ["화자 1", "민성"])
    }
}

// MARK: - Pipeline

private struct StubAttributor: SpeakerAttributor {
    let names: [String]
    func speakers(for transcript: AttributedTranscript, context: SpeakerContext) async throws -> [String] {
        Array(names.prefix(transcript.turns.count))
    }
}

private struct FailingAttributor: SpeakerAttributor {
    func speakers(for transcript: AttributedTranscript, context: SpeakerContext) async throws -> [String] {
        throw URLError(.notConnectedToInternet)
    }
}

private struct FixedTranscriber: FinalTranscriber {
    let texts: [String]
    func transcribe(fileURL: URL, channel: CaptureChannel, hints: TranscriptHints) async throws -> Transcript {
        Transcript(channel: channel, segments: texts.enumerated().map { index, text in
            Transcript.Segment(text: text, start: Double(index), end: Double(index) + 0.9)
        })
    }
}

private func audioFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("arca-attr-\(UUID().uuidString).m4a")
    try Data(repeating: 1, count: 8_192).write(to: url)
    return url
}

@Suite struct PipelineAttributionTests {
    @Test func namesComeBackOnTheTranscriptAndSameSpeakerLinesRegroup() async throws {
        let mic = try audioFile()
        defer { try? FileManager.default.removeItem(at: mic) }
        let pipeline = ProcessingPipeline(
            finalTranscriber: FixedTranscriber(texts: ["다음 주까지 되나요?", "네 제가 할게요.", "금요일까지요.", "좋아요."]),
            summarizer: nil,
            speakerAttributor: StubAttributor(names: ["김대표", "민성", "민성", "김대표"]))

        let output = try await pipeline.process(files: [.microphone: mic], ownerName: "민성")

        #expect(output.speakersAttributed)
        #expect(output.transcript.turns.map(\.speakerKey) == ["김대표", "민성", "김대표"])
        #expect(output.transcript.turns[1].text == "네 제가 할게요. 금요일까지요.")
    }

    @Test func aFailedAttributionKeepsTheTranscript() async throws {
        let mic = try audioFile()
        defer { try? FileManager.default.removeItem(at: mic) }
        let pipeline = ProcessingPipeline(
            finalTranscriber: FixedTranscriber(texts: ["하나", "둘"]),
            summarizer: nil,
            speakerAttributor: FailingAttributor())

        let output = try await pipeline.process(files: [.microphone: mic], ownerName: "민성")

        #expect(!output.speakersAttributed)
        #expect(output.transcript.turns.count == 1)
        #expect(output.transcript.turns[0].text == "하나 둘")
    }

    @Test func liveFallbackStaysOneTurnPerStoredSegment() async throws {
        let mic = try audioFile()
        defer { try? FileManager.default.removeItem(at: mic) }
        let live = AttributedTranscript(turns: [
            SpeakerTurn(speakerKey: "Me", text: "a", start: 0, end: 1, channel: .microphone),
            SpeakerTurn(speakerKey: "Me", text: "b", start: 1, end: 2, channel: .microphone),
            SpeakerTurn(speakerKey: "Me", text: "c", start: 2, end: 3, channel: .microphone),
        ])
        let pipeline = ProcessingPipeline(
            finalTranscriber: FixedTranscriber(texts: []),
            summarizer: nil,
            speakerAttributor: StubAttributor(names: ["민성", "민성", "화자 1"]))

        let output = try await pipeline.process(files: [.microphone: mic], ownerName: "민성", liveFallback: live)

        #expect(output.transcriptSource == .liveSegments)
        #expect(output.speakersAttributed)
        #expect(output.transcript.turns.map(\.speakerKey) == ["민성", "민성", "화자 1"])
    }

    /// Whisper returned a whole exchange as one segment during testing.
    @Test func oneLongSegmentBecomesSentencesForAttribution() async throws {
        let mic = try audioFile()
        defer { try? FileManager.default.removeItem(at: mic) }
        let pipeline = ProcessingPipeline(
            finalTranscriber: FixedTranscriber(texts: ["민성씨, 준비될까요? 네, 금요일까지 올릴게요. Great, thanks."]),
            summarizer: nil,
            speakerAttributor: StubAttributor(names: ["화자 1", "민성", "화자 1"]))

        let output = try await pipeline.process(files: [.microphone: mic], ownerName: "민성")

        #expect(output.speakersAttributed)
        #expect(output.transcript.turns.map(\.text) == ["민성씨, 준비될까요?", "네, 금요일까지 올릴게요.", "Great, thanks."])
        #expect(output.transcript.turns.map(\.speakerKey) == ["화자 1", "민성", "화자 1"])
        let times = output.transcript.turns.map(\.start)
        #expect(times == times.sorted() && times[0] == 0)
    }

    @Test func sentenceSplittingKeepsDecimalsAndSharesTime() {
        let pieces = ProcessingPipeline.sentences("가격은 19.5달러예요. 좋아요!", start: 10, end: 20)
        #expect(pieces.map(\.0) == ["가격은 19.5달러예요.", "좋아요!"])
        #expect(pieces.first?.1 == 10 && abs((pieces.last?.2 ?? 0) - 20) < 0.001)
    }

    @Test func anAlreadyNamedTranscriptIsLeftAlone() {
        let named = AttributedTranscript(turns: [
            SpeakerTurn(speakerKey: "민성", text: "a", start: 0, end: 1, channel: .microphone),
            SpeakerTurn(speakerKey: "화자 1", text: "b", start: 1, end: 2, channel: .microphone),
        ])
        #expect(!ProcessingPipeline.needsAttribution(named))
    }
}

// MARK: - Retry

private struct Flaky: TransientError {
    let isTransient: Bool
}

private final class Attempts: @unchecked Sendable {
    var count = 0
}

@Suite struct TransientRetryTests {
    @Test func transientFailuresAreRetriedUntilTheyPass() async throws {
        let attempts = Attempts()
        let value = try await withTransientRetry(delays: [.zero, .zero, .zero]) {
            attempts.count += 1
            if attempts.count < 3 { throw Flaky(isTransient: true) }
            return 42
        }
        #expect(value == 42)
        #expect(attempts.count == 3)
    }

    @Test func permanentFailuresAreNotRetried() async {
        let attempts = Attempts()
        await #expect(throws: Flaky.self) {
            try await withTransientRetry(delays: [.zero, .zero]) {
                attempts.count += 1
                throw Flaky(isTransient: false)
            }
        }
        #expect(attempts.count == 1)
    }

    @Test func retriesStopWhenTheDelaysRunOut() async {
        let attempts = Attempts()
        await #expect(throws: Flaky.self) {
            try await withTransientRetry(delays: [.zero, .zero]) {
                attempts.count += 1
                throw Flaky(isTransient: true)
            }
        }
        #expect(attempts.count == 3)
    }

    @Test func httpStatusesAreClassified() {
        #expect(isTransientHTTPStatus(529))
        #expect(isTransientHTTPStatus(429))
        #expect(!isTransientHTTPStatus(401))
        #expect(!isTransientHTTPStatus(400))
        #expect(!isTransientTransportError(URLError(.cancelled)))
        #expect(isTransientTransportError(URLError(.networkConnectionLost)))
    }
}

// MARK: - Summary failure

private struct BrokenSummarizer: Summarizer {
    func summarize(_ transcript: AttributedTranscript, userNotes: String?, style: NoteStyle) async throws -> MeetingNotes {
        throw ClaudeSummarizerError.api(status: 400, message: "credit balance is too low")
    }
}

@Suite struct SummaryFailureTests {
    /// A failed summary used to throw away the finished cloud transcript.
    @Test func aFailedSummaryKeepsTheTranscript() async throws {
        let mic = try audioFile()
        defer { try? FileManager.default.removeItem(at: mic) }
        let pipeline = ProcessingPipeline(finalTranscriber: FixedTranscriber(texts: ["회의 내용", "다음 안건"]),
                                          summarizer: BrokenSummarizer())

        let output = try await pipeline.process(files: [.microphone: mic], ownerName: "민성")

        #expect(output.transcriptSource == .finalPass)
        #expect(output.transcript.turns.isEmpty == false)
        #expect(output.notes == nil)
        #expect(output.summaryError?.contains("credit balance") == true)
    }
}
