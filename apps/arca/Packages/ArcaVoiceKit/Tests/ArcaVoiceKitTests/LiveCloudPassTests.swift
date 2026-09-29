import Testing
import Foundation
@testable import ArcaVoiceKit
@testable import Intelligence

/// The whole cloud pass against a real ARCA Cloud: chunked whisper through the
/// invite-authenticated proxy, Claude speaker attribution, Claude notes.
///
/// Runs only when pointed at a server, because it spends real API money:
///
///     ARCA_LIVE_BASE=http://localhost:4190 ARCA_LIVE_INVITE=<code> \
///     ARCA_LIVE_AUDIO=/path/meeting.caf swift test --filter LiveCloudPass
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ARCA_LIVE_BASE"] != nil))
struct LiveCloudPassTests {
    private let env = ProcessInfo.processInfo.environment

    @Test func cloudPassTranscribesAttributesAndSummarizes() async throws {
        let base = try #require(env["ARCA_LIVE_BASE"].flatMap(URL.init(string:)))
        let invite = try #require(env["ARCA_LIVE_INVITE"])
        let audio = URL(fileURLWithPath: try #require(env["ARCA_LIVE_AUDIO"]))
        let owner = env["ARCA_LIVE_OWNER"] ?? "민성"
        let language = env["ARCA_LIVE_LANG"] ?? "ko"
        let messages = base.appendingPathComponent("api/arca/cloud/messages")

        let pipeline = ProcessingPipeline(
            finalTranscriber: OpenAIDiarizedTranscriber(
                apiKey: invite, endpoint: base.appendingPathComponent("api/arca/transcribe"), auth: .arcaCloud),
            summarizer: ClaudeSummarizer(apiKey: invite, endpoint: messages),
            speakerAttributor: ClaudeSpeakerAttributor(apiKey: invite, endpoint: messages))

        let output = try await pipeline.process(
            files: [.microphone: audio], ownerName: owner,
            hints: TranscriptHints(vocabulary: [owner], languageCodes: [language]))

        print("---- transcript (\(output.transcript.turns.count) turns, attributed: \(output.speakersAttributed))")
        for turn in output.transcript.turns {
            print("[\(ClaudeSummarizer.timecode(turn.start))] \(turn.speakerKey): \(turn.text)")
        }
        if let summaryError = output.summaryError { print("---- summary error: \(summaryError)") }
        if let attributionError = output.attributionError { print("---- attribution error: \(attributionError)") }
        if let notes = output.notes {
            print("---- \(notes.title)\n\(notes.summaryMarkdown)")
            print("---- decisions:\n" + notes.decisions.map { "- \($0)" }.joined(separator: "\n"))
            print("---- actions:\n" + notes.actionItems.map {
                "- \($0.text) — \($0.assigneeName ?? "?") \($0.due.map { "\($0)" } ?? $0.dueText ?? "")"
            }.joined(separator: "\n"))
        }

        #expect(output.transcriptSource == .finalPass)
        #expect(output.channelErrors.isEmpty)
        #expect(output.speakersAttributed)
        #expect(Set(output.transcript.turns.map(\.speakerKey)).count >= 2)
        let starts = output.transcript.turns.map(\.start)
        #expect(starts == starts.sorted(), "turns out of order across chunk boundaries")
        #expect(output.notes?.actionItems.isEmpty == false)
    }
}
