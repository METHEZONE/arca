import Testing
import Foundation
import ArcaVoiceKit

@Suite struct OpenAIDiarizedTranscriberTests {
    @Test func decodesDiarizedSegmentsWithSpeakerLabels() throws {
        let json = """
        {
          "task": "transcribe",
          "language": "ko",
          "text": "안녕하세요 반갑습니다",
          "segments": [
            {"speaker": "A", "start": 0.0, "end": 1.5, "text": "안녕하세요"},
            {"speaker": "B", "start": 1.6, "end": 3.0, "text": "반갑습니다"}
          ]
        }
        """
        let transcript = try OpenAIDiarizedTranscriber.decodeTranscript(
            from: Data(json.utf8), channel: .systemAudio
        )

        #expect(transcript.channel == .systemAudio)
        #expect(transcript.languageCode == "ko")
        #expect(transcript.segments.count == 2)
        #expect(transcript.segments.map(\.text) == ["안녕하세요", "반갑습니다"])
        #expect(transcript.segments.map(\.speakerLabel) == ["A", "B"])
        #expect(transcript.segments[0].start == 0.0)
        #expect(transcript.segments[0].end == 1.5)
        #expect(transcript.segments[1].start == 1.6)
    }

    @Test func decodesEmptyWhenNoSegments() throws {
        let json = #"{"language": "en", "text": ""}"#
        let transcript = try OpenAIDiarizedTranscriber.decodeTranscript(
            from: Data(json.utf8), channel: .microphone
        )
        #expect(transcript.segments.isEmpty)
        #expect(transcript.channel == .microphone)
    }

    @Test func toleratesMissingTimestampsAndSpeaker() throws {
        let json = #"{"segments": [{"text": "just words"}]}"#
        let transcript = try OpenAIDiarizedTranscriber.decodeTranscript(
            from: Data(json.utf8), channel: .microphone
        )
        #expect(transcript.segments.count == 1)
        #expect(transcript.segments[0].start == 0)
        #expect(transcript.segments[0].end == 0)
        #expect(transcript.segments[0].speakerLabel == nil)
    }

    @Test func extractsApiErrorMessage() {
        let json = #"{"error": {"message": "Invalid file format.", "type": "invalid_request_error"}}"#
        let message = OpenAIDiarizedTranscriber.apiErrorMessage(from: Data(json.utf8))
        #expect(message == "Invalid file format.")
    }

    @Test func apiErrorFallsBackToRawBody() {
        let raw = "Bad Gateway"
        let message = OpenAIDiarizedTranscriber.apiErrorMessage(from: Data(raw.utf8))
        #expect(message == "Bad Gateway")
    }

    @Test func multipartBodySetsDiarizeFields() throws {
        let body = OpenAIDiarizedTranscriber.multipartBody(
            boundary: "BND",
            fileName: "mic.wav",
            audioData: Data([0x01, 0x02, 0x03]),
            model: "gpt-4o-transcribe-diarize",
            languageHint: "ko"
        )
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("name=\"model\""))
        #expect(text.contains("gpt-4o-transcribe-diarize"))
        #expect(text.contains("name=\"response_format\""))
        #expect(text.contains("diarized_json"))
        #expect(text.contains("name=\"chunking_strategy\""))
        #expect(text.contains("auto"))
        #expect(text.contains("name=\"language\""))
        #expect(text.contains("filename=\"mic.wav\""))
        #expect(text.contains("Content-Type: audio/wav"))
        #expect(text.contains("--BND--"))
    }

    @Test func multipartBodyOmitsLanguageWhenNil() throws {
        let body = OpenAIDiarizedTranscriber.multipartBody(
            boundary: "BND",
            fileName: "mic.wav",
            audioData: Data(),
            model: "gpt-4o-transcribe-diarize",
            languageHint: nil
        )
        let text = String(decoding: body, as: UTF8.self)
        #expect(!text.contains("name=\"language\""))
    }
}

@Suite struct ClaudeSummarizerTests {
    private func toolUseResponse(input: String) -> Data {
        let json = """
        {
          "id": "msg_1",
          "type": "message",
          "role": "assistant",
          "model": "claude-sonnet-5",
          "content": [
            {"type": "text", "text": "Here are the notes."},
            {"type": "tool_use", "id": "toolu_1", "name": "record_meeting_notes", "input": \(input)}
          ],
          "stop_reason": "tool_use"
        }
        """
        return Data(json.utf8)
    }

    @Test func parsesNotesFromToolUseBlock() throws {
        let input = """
        {
          "title": "주간 회의",
          "summaryMarkdown": "## 요약\\n제품 로드맵 논의",
          "decisions": ["출시일을 6월로 확정"],
          "actionItems": [
            {"text": "디자인 시안 준비", "assigneeName": "민성", "due": "2026-07-10"},
            {"text": "QA 계획 작성"}
          ]
        }
        """
        let notes = try ClaudeSummarizer.parseNotes(
            from: toolUseResponse(input: input), style: .meetingSummary, userNotes: nil
        )

        #expect(notes.title == "주간 회의")
        #expect(notes.summaryMarkdown.contains("제품 로드맵"))
        #expect(notes.decisions == ["출시일을 6월로 확정"])
        #expect(notes.actionItems.count == 2)
        #expect(notes.actionItems[0].text == "디자인 시안 준비")
        #expect(notes.actionItems[0].assigneeName == "민성")
        #expect(notes.actionItems[0].due != nil)
        #expect(notes.actionItems[1].assigneeName == nil)
        #expect(notes.actionItems[1].due == nil)
        // meetingSummary style never surfaces enhanced notes.
        #expect(notes.enhancedNotesMarkdown == nil)
    }

    @Test func surfacesEnhancedNotesOnlyForEnhancedStyleWithUserNotes() throws {
        let input = """
        {
          "title": "메모",
          "summaryMarkdown": "요약",
          "decisions": [],
          "actionItems": [],
          "enhancedNotesMarkdown": "정리된 노트"
        }
        """
        let withNotes = try ClaudeSummarizer.parseNotes(
            from: toolUseResponse(input: input), style: .enhancedNotes, userNotes: "rough"
        )
        #expect(withNotes.enhancedNotesMarkdown == "정리된 노트")

        // Same payload, but no user notes to enhance → drop it.
        let withoutNotes = try ClaudeSummarizer.parseNotes(
            from: toolUseResponse(input: input), style: .enhancedNotes, userNotes: nil
        )
        #expect(withoutNotes.enhancedNotesMarkdown == nil)

        // Wrong style → drop it even if the model returned it.
        let wrongStyle = try ClaudeSummarizer.parseNotes(
            from: toolUseResponse(input: input), style: .actionItems, userNotes: "rough"
        )
        #expect(wrongStyle.enhancedNotesMarkdown == nil)
    }

    @Test func throwsWhenNoToolUseBlock() {
        let json = """
        {"content": [{"type": "text", "text": "I could not produce notes."}], "stop_reason": "end_turn"}
        """
        #expect(throws: ClaudeSummarizerError.self) {
            try ClaudeSummarizer.parseNotes(from: Data(json.utf8), style: .meetingSummary, userNotes: nil)
        }
    }

    @Test func extractsApiErrorMessage() {
        let json = #"{"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}}"#
        let message = ClaudeSummarizer.apiErrorMessage(from: Data(json.utf8))
        #expect(message == "invalid x-api-key")
    }

    @Test func requestBodyForcesTheStructuredTool() throws {
        let transcript = AttributedTranscript(
            turns: [
                SpeakerTurn(speakerKey: "owner", text: "시작합시다", start: 0, end: 1, channel: .microphone),
                SpeakerTurn(speakerKey: "S1", text: "네", start: 1, end: 2, channel: .systemAudio),
            ],
            speakerNames: ["owner": "민성"]
        )
        let body = ClaudeSummarizer.requestBody(
            model: "claude-sonnet-5",
            maxTokens: 4096,
            transcript: transcript,
            userNotes: nil,
            style: .meetingSummary
        )

        #expect(body["model"] as? String == "claude-sonnet-5")
        let toolChoice = body["tool_choice"] as? [String: Any]
        #expect(toolChoice?["type"] as? String == "tool")
        #expect(toolChoice?["name"] as? String == "record_meeting_notes")

        let tools = body["tools"] as? [[String: Any]]
        #expect(tools?.first?["name"] as? String == "record_meeting_notes")
        // The forced tool must be encodable to JSON as-is.
        #expect(JSONSerialization.isValidJSONObject(body))
    }

    @Test func formatTranscriptResolvesSpeakerNames() {
        let transcript = AttributedTranscript(
            turns: [
                SpeakerTurn(speakerKey: "owner", text: "안녕", start: 0, end: 1, channel: .microphone),
                SpeakerTurn(speakerKey: "S1", text: "반가워요", start: 1, end: 2, channel: .systemAudio),
            ],
            speakerNames: ["owner": "민성"]
        )
        let text = ClaudeSummarizer.formatTranscript(transcript)
        #expect(text == "민성: 안녕\nS1: 반가워요")
    }

    @Test func parsesIsoAndDateOnlyDueDates() {
        #expect(ClaudeSummarizer.parseDate("2026-07-10") != nil)
        #expect(ClaudeSummarizer.parseDate("2026-07-10T09:00:00Z") != nil)
        #expect(ClaudeSummarizer.parseDate("") == nil)
        #expect(ClaudeSummarizer.parseDate(nil) == nil)
        #expect(ClaudeSummarizer.parseDate("someday") == nil)
    }
}
