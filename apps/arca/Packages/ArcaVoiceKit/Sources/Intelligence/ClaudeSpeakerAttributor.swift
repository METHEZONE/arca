import Foundation
import ArcaVoiceCore

/// Who said each line of a transcript that has no voice information in it.
///
/// An iPhone records one microphone, and the transcription engines ARCA uses
/// on it can't tell voices apart — so every line used to be filed under the
/// owner, and "I'll send the contract" from the other side of the table became
/// the owner's to-do. Conversation carries most of what's needed instead:
/// questions and their answers alternate, people address each other by name,
/// a "네, 제가 할게요" answers someone else's request.
public protocol SpeakerAttributor: Sendable {
    /// One display name per turn, in turn order. The text of the transcript is
    /// never touched — only who it's attributed to.
    func speakers(for transcript: AttributedTranscript, context: SpeakerContext) async throws -> [String]
}

public struct SpeakerContext: Sendable {
    /// The label the owner's lines get — the same name `MeetingDelegation`
    /// matches when deciding which action items are theirs.
    public var ownerName: String
    /// Names expected in the room (typed before the meeting or read off a call).
    public var participants: [String]

    public init(ownerName: String, participants: [String] = []) {
        self.ownerName = ownerName
        self.participants = participants
    }
}

public enum SpeakerAttributionError: Error, LocalizedError {
    case tooLong(lines: Int)
    case unusableAnswer(String)

    public var errorDescription: String? {
        switch self {
        case .tooLong(let lines): return "Transcript too long to attribute in one pass (\(lines) lines)."
        case .unusableAnswer(let detail): return "Speaker attribution came back unusable: \(detail)"
        }
    }
}

public struct ClaudeSpeakerAttributor: SpeakerAttributor {
    static let toolName = "assign_speakers"
    /// Roughly four hours of conversation, well inside the model's context.
    /// ponytail: one call per transcript; window it with carried-over speaker
    /// ids if recordings longer than this become common.
    static let maxCharacters = 180_000

    private let apiKey: String
    private let model: String
    private let endpoint: URL
    private let urlSession: URLSession

    public init(apiKey: String,
                model: String = "claude-sonnet-5",
                endpoint: URL = ArcaCloud.anthropicMessagesURL,
                urlSession: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.urlSession = urlSession
    }

    public func speakers(for transcript: AttributedTranscript, context: SpeakerContext) async throws -> [String] {
        let turns = transcript.turns
        guard turns.count >= 2 else {
            return turns.map { _ in context.ownerName }
        }
        let lines = Self.numberedLines(turns)
        guard lines.count <= Self.maxCharacters else {
            throw SpeakerAttributionError.tooLong(lines: turns.count)
        }

        let body: [String: Any] = [
            "model": model,
            // Room for a long meeting's ranges; a cut-off answer is rejected
            // and the transcript just stays unattributed.
            "max_tokens": 8000,
            "system": Self.systemPrompt(ownerName: context.ownerName,
                                        multiChannel: Set(turns.map(\.channel)).count > 1),
            "messages": [["role": "user", "content": Self.userPrompt(lines: lines, count: turns.count,
                                                                      context: context)]],
            "tools": [Self.toolDefinition],
            "tool_choice": ["type": "tool", "name": Self.toolName],
        ]
        let httpBody = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        // A miscounted answer (measured: about 1 in 20) is worth one more ask.
        var attempt = 0
        while true {
            attempt += 1
            let data = try await withTransientRetry {
                try await ClaudeSummarizer.send(request, body: httpBody, session: urlSession)
            }
            AIUsageLog.recordResponse(provider: "anthropic", model: model, source: "speakers", data: data)
            do {
                guard let input = try ClaudeSummarizer.toolUseInput(from: data) else {
                    throw SpeakerAttributionError.unusableAnswer("no tool call")
                }
                let answer = try JSONDecoder().decode(Answer.self,
                                                      from: JSONSerialization.data(withJSONObject: input))
                return try Self.resolve(answer, lineCount: turns.count, ownerName: context.ownerName,
                                        korean: ClaudeSummarizer.containsHangul(lines))
            } catch where attempt < 2 {
                continue
            }
        }
    }

    // MARK: - Prompt

    static func numberedLines(_ turns: [SpeakerTurn]) -> String {
        let multiChannel = Set(turns.map(\.channel)).count > 1
        return turns.enumerated().map { index, turn in
            let tag = multiChannel ? (turn.channel == .microphone ? " [mic]" : " [remote]") : ""
            let text = turn.text.replacingOccurrences(of: "\n", with: " ")
            return "\(index + 1)\(tag) \(text)"
        }.joined(separator: "\n")
    }

    static func systemPrompt(ownerName: String, multiChannel: Bool) -> String {
        var lines = [
            "You work out who said each line of a meeting transcript produced by speech recognition. There is no voice information — decide from the conversation itself.",
            "",
            "Clues: questions and answers alternate between people; people address each other by name or title (\"민성씨\", \"대표님\"); self-introductions; an agreement like \"네, 제가 할게요\" answers someone else's request; honorific vs casual speech differs between speakers; a line that continues the previous sentence is usually the same speaker; a person tends to keep the topic they own.",
            "",
            "Rules:",
            "- Use the fewest speakers that explain the conversation. A voice memo, a lecture, or dictation is one speaker.",
            "- The recording belongs to \(ownerName). If they speak, mark exactly one speaker isOwner=true — the most likely one: the person others address by that name, or the one the others are talking to. Whoever says a name is talking TO that person, so the line \"\(ownerName)씨, …\" is never \(ownerName)'s own line; the reply that follows usually is. If they clearly never speak, mark none.",
            "- name: only a name the transcript actually states for that person (addressed or introduced), or one from the participant list that clearly fits. Otherwise an empty string. Never invent names.",
            "- lineSpeakers: exactly N entries, one speaker id per line in line order (entry 1 is line 1).",
        ]
        if multiChannel {
            lines.append("- Lines tagged [remote] came from the call audio: never the owner. Lines tagged [mic] are the owner unless the conversation shows someone else in the room with them.")
        }
        lines.append("- Call the \(toolName) tool exactly once.")
        return lines.joined(separator: "\n")
    }

    static func userPrompt(lines: String, count: Int, context: SpeakerContext) -> String {
        var parts = ["Recording owner: \(context.ownerName)"]
        let others = context.participants.filter {
            $0.caseInsensitiveCompare(context.ownerName) != .orderedSame
        }
        if !others.isEmpty {
            parts.append("Expected participants: \(others.joined(separator: ", "))")
        }
        parts.append("Transcript (\(count) lines):\n\(lines)")
        return parts.joined(separator: "\n\n")
    }

    static var toolDefinition: [String: Any] { [
        "name": toolName,
        "description": "Record who said each line.",
        "strict": true,
        "input_schema": [
            "type": "object",
            "properties": [
                "speakers": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "id": ["type": "string", "description": "Short id used in lineSpeakers: A, B, C…"],
                            "name": ["type": "string", "description": "Stated name, or empty string."],
                            "isOwner": ["type": "boolean"],
                        ],
                        "required": ["id", "name", "isOwner"],
                        "additionalProperties": false,
                    ],
                ],
                "lineSpeakers": [
                    "type": "array",
                    "description": "The speaker id for each line, in order — exactly one entry per line.",
                    "items": ["type": "string"],
                ],
            ],
            "required": ["speakers", "lineSpeakers"],
            "additionalProperties": false,
        ],
    ] }

    // MARK: - Answer

    struct Answer: Decodable {
        struct Speaker: Decodable {
            var id: String
            var name: String?
            var isOwner: Bool?
        }
        var speakers: [Speaker]
        var lineSpeakers: [String]
    }

    /// Turns the model's answer into one label per line.
    ///
    /// A list a line or two off (the model miscounting a long transcript) is
    /// padded or trimmed — a gap is far more likely a continuation than a new
    /// voice — but an answer that places most lines nowhere is rejected rather
    /// than half-trusted.
    static func resolve(_ answer: Answer, lineCount: Int, ownerName: String, korean: Bool) throws -> [String] {
        var labels: [String: String] = [:]
        var genericIndex = 0
        var ownerTaken = false
        var raw = answer.lineSpeakers.prefix(lineCount).map { Optional($0.trimmingCharacters(in: .whitespaces)) }
        raw += [String?](repeating: nil, count: max(0, lineCount - raw.count))
        let known = Dictionary(answer.speakers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func label(for id: String) -> String? {
            if let existing = labels[id] { return existing }
            guard let speaker = known[id] else { return nil }
            let name = speaker.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let resolved: String
            if speaker.isOwner == true && !ownerTaken {
                ownerTaken = true
                resolved = ownerName
            } else if !name.isEmpty, name.caseInsensitiveCompare(ownerName) != .orderedSame {
                resolved = name
            } else {
                genericIndex += 1
                resolved = korean ? "화자 \(genericIndex)" : "Speaker \(genericIndex)"
            }
            labels[id] = resolved
            return resolved
        }

        var result = raw.map { $0.flatMap(label(for:)) }
        let placed = result.compactMap { $0 }.count
        guard placed * 5 >= lineCount * 4 else {
            throw SpeakerAttributionError.unusableAnswer("placed \(placed) of \(lineCount) lines")
        }
        // Fill gaps from the previous line, and a leading gap from the first placed one.
        var previous = result.first { $0 != nil } ?? nil
        for index in result.indices {
            if let current = result[index] { previous = current } else { result[index] = previous }
        }
        return result.map { $0 ?? ownerName }
    }
}
