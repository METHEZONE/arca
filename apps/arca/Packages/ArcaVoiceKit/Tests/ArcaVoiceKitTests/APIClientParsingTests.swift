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

    @Test func multipartFileStreamsAudioWithWhisperFields() throws {
        let audio = FileManager.default.temporaryDirectory
            .appendingPathComponent("arca-test-\(UUID().uuidString).wav")
        try Data([0x01, 0x02, 0x03]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }

        let bodyFile = try OpenAIDiarizedTranscriber.writeMultipartFile(
            boundary: "BND",
            audioURL: audio,
            model: "whisper-1",
            language: "ko",
            prompt: "민성, ARCA"
        )
        defer { try? FileManager.default.removeItem(at: bodyFile) }

        let body = try Data(contentsOf: bodyFile)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("name=\"model\""))
        #expect(text.contains("whisper-1"))
        #expect(text.contains("name=\"response_format\""))
        #expect(text.contains("verbose_json"))
        // Sampling is what makes whisper loop on quiet passages.
        #expect(text.contains("name=\"temperature\""))
        #expect(text.contains("name=\"language\""))
        #expect(text.contains("name=\"prompt\""))
        #expect(text.contains("민성, ARCA"))
        #expect(text.contains("filename=\"\(audio.lastPathComponent)\""))
        #expect(text.contains("Content-Type: audio/wav"))
        #expect(text.contains("--BND--"))
        #expect(body.contains(Data([0x01, 0x02, 0x03])))
    }

    /// Whisper without a language guesses, and on Korean room audio it guesses
    /// English and then hallucinates. There must always be a hint.
    @Test func languageAlwaysResolvesEvenWithNoHint() {
        #expect(OpenAIDiarizedTranscriber.resolvedLanguage(
            TranscriptHints(languageCodes: [])) == "ko")
        #expect(OpenAIDiarizedTranscriber.resolvedLanguage(
            TranscriptHints(languageCodes: ["en"])) == "en")
        #expect(OpenAIDiarizedTranscriber.resolvedLanguage(
            TranscriptHints(languageCodes: [" "])) == "ko")
    }

    @Test func promptHintCarriesVocabularyOrNothing() {
        #expect(OpenAIDiarizedTranscriber.promptHint(TranscriptHints()) == nil)
        #expect(OpenAIDiarizedTranscriber.promptHint(
            TranscriptHints(vocabulary: ["민성", " ", "ARCA"])) == "민성, ARCA")
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
          "topics": [
            {
              "title": "보조지표 선정",
              "timeRange": "00:03:12–00:21:40",
              "keyPoints": ["RSI 30/70 기준", "MACD 12-26-9"],
              "quotes": ["RSI가 30 밑으로 가면 분할 매수합니다"]
            }
          ],
          "decisions": [
            {"decision": "출시일을 6월로 확정", "rationale": "QA 일정이 5월까지 밀려서", "decidedBy": "민성"}
          ],
          "actionItems": [
            {"text": "디자인 시안 준비", "assigneeName": "민성", "due": "2026-07-10"},
            {"text": "QA 계획 작성", "assigneeName": "미정", "due": "다음 주 화요일"},
            {"text": "API 문서 정리", "assigneeName": "", "due": "미정"}
          ],
          "openQuestions": ["수수료 협상은 누가 담당할지"]
        }
        """
        let notes = try ClaudeSummarizer.parseNotes(
            from: toolUseResponse(input: input), style: .meetingSummary, userNotes: nil
        )

        #expect(notes.title == "주간 회의")
        #expect(notes.summaryMarkdown.contains("제품 로드맵"))

        // Topic detail and open questions ride inside summaryMarkdown so every
        // existing reader picks them up.
        #expect(notes.summaryMarkdown.contains("## 주제별 상세"))
        #expect(notes.summaryMarkdown.contains("**00:03:12–00:21:40 · 보조지표 선정**"))
        #expect(notes.summaryMarkdown.contains("- RSI 30/70 기준"))
        #expect(notes.summaryMarkdown.contains("> RSI가 30 밑으로 가면 분할 매수합니다"))
        #expect(notes.summaryMarkdown.contains("### 미해결 질문"))
        #expect(notes.summaryMarkdown.contains("- 수수료 협상은 누가 담당할지"))

        #expect(notes.topics.count == 1)
        #expect(notes.topics[0].keyPoints.count == 2)
        #expect(notes.openQuestions == ["수수료 협상은 누가 담당할지"])

        // Structured decisions, plus the flattened lines the wire format keeps.
        #expect(notes.decisionDetails.count == 1)
        #expect(notes.decisionDetails[0].rationale == "QA 일정이 5월까지 밀려서")
        #expect(notes.decisionDetails[0].decidedBy == "민성")
        #expect(notes.decisions == ["출시일을 6월로 확정 — 근거: QA 일정이 5월까지 밀려서 (결정: 민성)"])

        #expect(notes.actionItems.count == 3)
        #expect(notes.actionItems[0].text == "디자인 시안 준비")
        #expect(notes.actionItems[0].assigneeName == "민성")
        #expect(notes.actionItems[0].due != nil)
        #expect(notes.actionItems[0].dueText == nil)
        // A stated-but-unparseable deadline is kept as text, not dropped.
        #expect(notes.actionItems[1].assigneeName == nil)   // "미정" folds to nil
        #expect(notes.actionItems[1].due == nil)
        #expect(notes.actionItems[1].dueText == "다음 주 화요일")
        #expect(notes.actionItems[1].dueDisplay == "다음 주 화요일")
        #expect(notes.actionItems[2].assigneeName == nil)
        // "미정" is the schema's explicit unknown, not a deadline to print twice.
        #expect(notes.actionItems[2].dueText == nil)
        #expect(notes.actionItems[2].dueDisplay == "미정")
        // meetingSummary style never surfaces enhanced notes.
        #expect(notes.enhancedNotesMarkdown == nil)
    }

    @Test func parsesDecisionsGivenAsPlainStrings() throws {
        let input = """
        {
          "title": "메모",
          "summaryMarkdown": "요약",
          "decisions": ["출시일을 6월로 확정"],
          "actionItems": []
        }
        """
        let notes = try ClaudeSummarizer.parseNotes(
            from: toolUseResponse(input: input), style: .meetingSummary, userNotes: nil
        )
        #expect(notes.decisions == ["출시일을 6월로 확정"])
        #expect(notes.decisionDetails[0].rationale == nil)
    }

    @Test func foldsUnknownPlaceholdersOutOfDecisionLines() throws {
        let input = """
        {
          "title": "메모",
          "summaryMarkdown": "요약",
          "decisions": [{"decision": "보류", "rationale": "미상", "decidedBy": "미상"}],
          "actionItems": []
        }
        """
        let notes = try ClaudeSummarizer.parseNotes(
            from: toolUseResponse(input: input), style: .meetingSummary, userNotes: nil
        )
        // The schema demands an explicit "미상" so the field is never dropped,
        // but it must not reach the rendered line.
        #expect(notes.decisions == ["보류"])
    }

    @Test func composedSummaryOmitsEmptySections() {
        let markdown = MeetingNotes.composeSummaryMarkdown(
            overview: "요약 본문", topics: [], openQuestions: [])
        #expect(markdown == "요약 본문")

        let noRange = MeetingNotes.composeSummaryMarkdown(
            overview: "",
            topics: [MeetingNotes.Topic(title: "가격", keyPoints: ["19달러"])],
            openQuestions: [])
        #expect(noRange == "## 주제별 상세\n\n**가격**\n- 19달러")
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
            maxTokens: 16000,
            transcript: transcript,
            userNotes: nil,
            style: .meetingSummary
        )

        #expect(body["model"] as? String == "claude-sonnet-5")
        #expect(body["max_tokens"] as? Int == 16000)
        let toolChoice = body["tool_choice"] as? [String: Any]
        #expect(toolChoice?["type"] as? String == "tool")
        #expect(toolChoice?["name"] as? String == "record_meeting_notes")

        let tools = body["tools"] as? [[String: Any]]
        #expect(tools?.first?["name"] as? String == "record_meeting_notes")
        // The detail-bearing fields must all be required, or the model drops them.
        let schema = tools?.first?["input_schema"] as? [String: Any]
        let required = Set((schema?["required"] as? [String]) ?? [])
        #expect(required.isSuperset(of: ["title", "summaryMarkdown", "topics", "decisions",
                                         "actionItems", "openQuestions"]))
        let properties = schema?["properties"] as? [String: Any]
        #expect(properties?["topics"] != nil)
        #expect(properties?["openQuestions"] != nil)
        // The forced tool must be encodable to JSON as-is.
        #expect(JSONSerialization.isValidJSONObject(body))
    }

    @Test func promptDemandsSpecificsRatherThanConciseness() {
        let system = ClaudeSummarizer.systemPrompt(style: .meetingSummary)
        // "concise" is what produced one-paragraph summaries of 100-minute meetings.
        #expect(!system.lowercased().contains("concise"))
        #expect(system.contains("[HH:MM:SS]"))
        #expect(system.contains("openQuestions"))
        #expect(system.contains("미정"))
        // Channel labels must never be turned into people's names.
        #expect(system.contains("AUDIO CHANNELS"))

        let transcript = AttributedTranscript(turns: [
            SpeakerTurn(speakerKey: "owner", text: "안녕", start: 0, end: 1, channel: .microphone),
        ], speakerNames: ["owner": "민성"])
        let user = ClaudeSummarizer.userPrompt(
            transcript: transcript, userNotes: nil, style: .meetingSummary)
        #expect(!user.lowercased().contains("concise"))
        #expect(user.contains("time-anchored"))
    }

    @Test func formatTranscriptStampsAndLabelsEveryTurn() {
        let transcript = AttributedTranscript(
            turns: [
                SpeakerTurn(speakerKey: "systemAudio:S2", text: "반가워요",
                            start: 3_671, end: 3_675, channel: .systemAudio),
                SpeakerTurn(speakerKey: "owner", text: "안녕", start: 0, end: 1, channel: .microphone),
                SpeakerTurn(speakerKey: "systemAudio:S1", text: "네",
                            start: 65, end: 66, channel: .systemAudio),
            ],
            speakerNames: ["owner": "민성"]
        )
        let text = ClaudeSummarizer.formatTranscript(transcript)
        // Time-ordered, zero-padded, and diarized remote voices stay distinct.
        #expect(text == """
        [00:00:00] 민성: 안녕
        [00:01:05] Other(S1): 네
        [01:01:11] Other(S2): 반가워요
        """)
    }

    @Test func formatTranscriptTreatsBareKeysAsResolvedNames() {
        // Stored segments carry the resolved speaker name in `speakerKey`.
        let transcript = AttributedTranscript(turns: [
            SpeakerTurn(speakerKey: "민성", text: "시작합시다", start: 0, end: 1, channel: .microphone),
            SpeakerTurn(speakerKey: "Other", text: "네", start: 2, end: 3, channel: .systemAudio),
        ])
        #expect(ClaudeSummarizer.formatTranscript(transcript) == """
        [00:00:00] 민성: 시작합시다
        [00:00:02] Other: 네
        """)
    }

    @Test func parsesIsoAndDateOnlyDueDates() {
        #expect(ClaudeSummarizer.parseDate("2026-07-10") != nil)
        #expect(ClaudeSummarizer.parseDate("2026-07-10T09:00:00Z") != nil)
        #expect(ClaudeSummarizer.parseDate("") == nil)
        #expect(ClaudeSummarizer.parseDate(nil) == nil)
        #expect(ClaudeSummarizer.parseDate("someday") == nil)
    }
}
