import Testing
import Foundation
import ArcaVoiceKit

// MARK: - Doubles

private struct StubTranscriber: FinalTranscriber {
    let result: Result<Transcript, StubError>
    /// Records that this tier was reached at all.
    let calls: Counter

    func transcribe(fileURL: URL, channel: CaptureChannel,
                    hints: TranscriptHints) async throws -> Transcript {
        calls.increment()
        return try result.get()
    }
}

private enum StubError: Error, LocalizedError {
    case cloudOutage
    case onDeviceUnavailable

    var errorDescription: String? {
        switch self {
        case .cloudOutage: return "OpenAI transcription failed (HTTP 503)"
        case .onDeviceUnavailable: return "On-device transcription found no speech"
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private struct StubSummarizer: Summarizer {
    let calls: Counter

    func summarize(_ transcript: AttributedTranscript, userNotes: String?,
                   style: NoteStyle) async throws -> MeetingNotes {
        calls.increment()
        return MeetingNotes(
            title: "Summarized \(transcript.turns.count) turn(s)",
            summaryMarkdown: transcript.turns.map(\.text).joined(separator: " | "))
    }
}

private func transcript(_ texts: [String], channel: CaptureChannel = .microphone) -> Transcript {
    Transcript(
        channel: channel,
        segments: texts.enumerated().map { index, text in
            Transcript.Segment(text: text, start: Double(index), end: Double(index) + 1)
        },
        languageCode: "ko")
}

/// A file big enough to clear `ProcessingPipeline`'s "this channel never
/// captured" floor, so the transcriber tier actually runs.
private func makeAudioFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("arca-test-\(UUID().uuidString).m4a")
    try Data(repeating: 0x41, count: 8192).write(to: url)
    return url
}

// MARK: - Tests

@Suite struct FallbackTranscriberTests {
    @Test func fallsBackToOnDeviceWhenTheCloudFails() async throws {
        let primaryCalls = Counter()
        let fallbackCalls = Counter()
        let chain = FallbackTranscriber(
            primary: StubTranscriber(result: .failure(.cloudOutage), calls: primaryCalls),
            fallback: StubTranscriber(result: .success(transcript(["안녕하세요"])), calls: fallbackCalls))

        let result = try await chain.transcribe(
            fileURL: URL(fileURLWithPath: "/dev/null"),
            channel: .microphone, hints: TranscriptHints())

        #expect(result.segments.map(\.text) == ["안녕하세요"])
        #expect(primaryCalls.count == 1)
        #expect(fallbackCalls.count == 1)
    }

    @Test func doesNotTouchTheFallbackWhenTheCloudWorks() async throws {
        let fallbackCalls = Counter()
        let chain = FallbackTranscriber(
            primary: StubTranscriber(result: .success(transcript(["cloud text"])), calls: Counter()),
            fallback: StubTranscriber(result: .success(transcript(["on-device"])), calls: fallbackCalls))

        let result = try await chain.transcribe(
            fileURL: URL(fileURLWithPath: "/dev/null"),
            channel: .microphone, hints: TranscriptHints())

        #expect(result.segments.map(\.text) == ["cloud text"])
        #expect(fallbackCalls.count == 0)
    }

    @Test func treatsAnEmptyCloudResultAsAFailure() async throws {
        // Whisper returning zero segments on real speech was the single most
        // common way a session ended up with no transcript at all.
        let fallbackCalls = Counter()
        let chain = FallbackTranscriber(
            primary: StubTranscriber(result: .success(transcript([])), calls: Counter()),
            fallback: StubTranscriber(result: .success(transcript(["recovered"])), calls: fallbackCalls))

        let result = try await chain.transcribe(
            fileURL: URL(fileURLWithPath: "/dev/null"),
            channel: .microphone, hints: TranscriptHints())

        #expect(result.segments.map(\.text) == ["recovered"])
        #expect(fallbackCalls.count == 1)
    }

    @Test func reportsTheCloudErrorWhenBothTiersFail() async {
        let chain = FallbackTranscriber(
            primary: StubTranscriber(result: .failure(.cloudOutage), calls: Counter()),
            fallback: StubTranscriber(result: .failure(.onDeviceUnavailable), calls: Counter()))

        await #expect(throws: StubError.cloudOutage) {
            try await chain.transcribe(
                fileURL: URL(fileURLWithPath: "/dev/null"),
                channel: .microphone, hints: TranscriptHints())
        }
    }
}

@Suite struct ProcessingPipelineFallbackTests {
    @Test func summarizesTheStoredLiveTranscriptWhenNothingCanTranscribe() async throws {
        // The old behavior threw here, before summarization — one cloud outage
        // left the session with neither a usable transcript nor any notes.
        let audio = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let summarizerCalls = Counter()
        let pipeline = ProcessingPipeline(
            finalTranscriber: StubTranscriber(result: .failure(.cloudOutage), calls: Counter()),
            summarizer: StubSummarizer(calls: summarizerCalls))

        let live = AttributedTranscript(turns: [
            SpeakerTurn(speakerKey: "Me", text: "라이브 전사 문장",
                        start: 0, end: 2, channel: .microphone),
        ])
        let output = try await pipeline.process(
            files: [.microphone: audio], ownerName: "Me", liveFallback: live)

        #expect(output.transcriptSource == .liveSegments)
        #expect(output.transcript.turns.map(\.text) == ["라이브 전사 문장"])
        #expect(output.notes?.summaryMarkdown == "라이브 전사 문장")
        #expect(summarizerCalls.count == 1)
        #expect(!output.channelErrors.isEmpty)
    }

    @Test func stillThrowsWhenThereIsNothingToFallBackOn() async throws {
        let audio = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let pipeline = ProcessingPipeline(
            finalTranscriber: StubTranscriber(result: .failure(.cloudOutage), calls: Counter()),
            summarizer: StubSummarizer(calls: Counter()))

        await #expect(throws: PipelineError.self) {
            try await pipeline.process(files: [.microphone: audio], ownerName: "Me")
        }
    }

    @Test func prefersTheFinalPassOverTheLiveFallback() async throws {
        let audio = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let pipeline = ProcessingPipeline(
            finalTranscriber: StubTranscriber(
                result: .success(transcript(["고품질 전사"])), calls: Counter()),
            summarizer: StubSummarizer(calls: Counter()))

        let live = AttributedTranscript(turns: [
            SpeakerTurn(speakerKey: "Me", text: "라이브", start: 0, end: 1, channel: .microphone),
        ])
        let output = try await pipeline.process(
            files: [.microphone: audio], ownerName: "Me", liveFallback: live)

        #expect(output.transcriptSource == .finalPass)
        #expect(output.transcript.turns.map(\.text) == ["고품질 전사"])
    }
}
