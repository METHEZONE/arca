import Foundation
import Testing
import ArcaVoiceKit

/// The pipeline's contract about *emptiness*.
///
/// These exist because of a real data-loss bug: the caller replaced a
/// recording's on-device transcript as soon as `process` returned without
/// throwing, and `process` returned successfully-with-nothing whenever a
/// channel transcribed to zero segments. A recorded conversation ended up
/// stored as an empty, "ready" session with no error anywhere. So the pipeline
/// has to make three cases distinguishable from the outside: it produced turns,
/// it ran and found nothing, or it broke.
@Suite struct ProcessingPipelineEmptyTests {
    /// A transcriber whose behaviour is dictated per channel.
    private struct StubTranscriber: FinalTranscriber {
        enum Behaviour: Sendable {
            case segments([String])
            case empty
            case failure
        }
        struct Boom: Error {}

        let byChannel: [CaptureChannel: Behaviour]

        func transcribe(fileURL: URL, channel: CaptureChannel,
                        hints: TranscriptHints) async throws -> Transcript {
            switch byChannel[channel] ?? .empty {
            case .failure:
                throw Boom()
            case .empty:
                return Transcript(channel: channel, segments: [])
            case .segments(let texts):
                return Transcript(channel: channel, segments: texts.enumerated().map { index, text in
                    Transcript.Segment(text: text, start: Double(index),
                                       end: Double(index) + 0.9, speakerLabel: "S1")
                })
            }
        }
    }

    /// Writes a file big enough to clear the header-only size guard, so the
    /// pipeline actually calls the transcriber for that channel.
    private func makeAudioFile(_ name: String, bytes: Int = 8192) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arca-pipeline-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let file = url.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: file)
        return file
    }

    @Test func realSpeechProducesTurnsAndNoEmptyReason() async throws {
        let mic = try makeAudioFile("mic.m4a")
        let pipeline = ProcessingPipeline(
            finalTranscriber: StubTranscriber(byChannel: [.microphone: .segments(["안녕하세요"])]),
            summarizer: nil)

        let output = try await pipeline.process(files: [.microphone: mic], ownerName: "민성")

        #expect(output.transcript.turns.count == 1)
        #expect(output.emptyReason == nil)
    }

    /// The exact shape of the bug: real audio in, zero segments back. It must
    /// not look like a normal successful pass, or the caller overwrites a good
    /// transcript with nothing.
    @Test func silentAudioReportsNoSpeechRatherThanPlainSuccess() async throws {
        let mic = try makeAudioFile("mic.m4a")
        let pipeline = ProcessingPipeline(
            finalTranscriber: StubTranscriber(byChannel: [.microphone: .empty]),
            summarizer: nil)

        let output = try await pipeline.process(files: [.microphone: mic], ownerName: "민성")

        #expect(output.transcript.turns.isEmpty)
        #expect(output.emptyReason == .noSpeechFound)
    }

    /// A header-only file is a capture that never happened — distinct from audio
    /// that contained no speech, because only one of the two is worth retrying.
    @Test func headerOnlyFileReportsNoAudioCaptured() async throws {
        let mic = try makeAudioFile("mic.m4a", bytes: 128)
        let pipeline = ProcessingPipeline(
            finalTranscriber: StubTranscriber(byChannel: [.microphone: .segments(["never called"])]),
            summarizer: nil)

        let output = try await pipeline.process(files: [.microphone: mic], ownerName: "민성")

        #expect(output.transcript.turns.isEmpty)
        #expect(output.emptyReason == .noAudioCaptured)
    }

    /// One live channel is enough. A failed sibling channel must not discard the
    /// half that worked.
    @Test func oneGoodChannelSurvivesAFailedSibling() async throws {
        let mic = try makeAudioFile("mic.m4a")
        let system = try makeAudioFile("system.m4a")
        let pipeline = ProcessingPipeline(
            finalTranscriber: StubTranscriber(byChannel: [
                .microphone: .segments(["내 목소리"]),
                .systemAudio: .failure,
            ]),
            summarizer: nil)

        let output = try await pipeline.process(
            files: [.microphone: mic, .systemAudio: system], ownerName: "민성")

        #expect(output.transcript.turns.count == 1)
        #expect(output.emptyReason == nil)
    }

    /// Nothing usable plus a real error has to throw, so the session is queued
    /// for retry instead of being quietly filed as finished-and-empty. This is
    /// the case the old dictionary-emptiness check got wrong: the silent channel
    /// occupied a key, so the collection looked non-empty and the throw was
    /// skipped.
    @Test func silentChannelPlusFailedChannelThrows() async throws {
        let mic = try makeAudioFile("mic.m4a")
        let system = try makeAudioFile("system.m4a")
        let pipeline = ProcessingPipeline(
            finalTranscriber: StubTranscriber(byChannel: [
                .microphone: .empty,
                .systemAudio: .failure,
            ]),
            summarizer: nil)

        await #expect(throws: PipelineError.self) {
            _ = try await pipeline.process(
                files: [.microphone: mic, .systemAudio: system], ownerName: "민성")
        }
    }

    @Test func everyChannelFailingThrows() async throws {
        let mic = try makeAudioFile("mic.m4a")
        let pipeline = ProcessingPipeline(
            finalTranscriber: StubTranscriber(byChannel: [.microphone: .failure]),
            summarizer: nil)

        await #expect(throws: PipelineError.self) {
            _ = try await pipeline.process(files: [.microphone: mic], ownerName: "민성")
        }
    }
}
