import Foundation
import ArcaVoiceCore

/// What one meeting-screen capture revealed about who's in the call.
public struct MeetingRoster: Sendable, Codable, Equatable {
    /// Participant names exactly as shown on tiles / the people panel,
    /// excluding the user's own tile ("You" / "나").
    public var participants: [String]
    /// The participant currently highlighted as speaking, if visible.
    public var activeSpeaker: String?

    public init(participants: [String], activeSpeaker: String? = nil) {
        self.participants = participants
        self.activeSpeaker = activeSpeaker
    }
}

/// Reads a video-call screenshot (Google Meet, Zoom, Teams…) with Claude
/// vision and extracts the visible participant roster. Same Messages API +
/// forced-tool pattern as ClaudeVisionPlanner.
public struct MeetingRosterReader: Sendable {
    private let apiKey: String
    private let model: String
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public init(apiKey: String, model: String = "claude-haiku-4-5-20251001") {
        self.apiKey = apiKey
        self.model = model
    }

    public func read(imageData: Data, mediaType: String = "image/jpeg") async throws -> MeetingRoster {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let tool: [String: Any] = [
            "name": "record_meeting_roster",
            "description": "Record the participants visible in this video-call screenshot.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "isVideoCall": [
                        "type": "boolean",
                        "description": "true only when the screenshot clearly shows a video-call UI (Google Meet, Zoom, Teams, FaceTime…)",
                    ],
                    "participants": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Participant names EXACTLY as written on tiles or the people panel. Exclude the user's own tile (labeled 'You', '나', '(you)'). Empty when no names are readable.",
                    ],
                    "activeSpeaker": [
                        "type": "string",
                        "description": "The participant whose tile is highlighted as currently speaking (colored border / waveform icon), if identifiable and not the user themselves. Omit when unsure.",
                    ],
                ],
                "required": ["isVideoCall", "participants"],
            ] as [String: Any],
        ]

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 512,
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": "record_meeting_roster"],
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image",
                     "source": ["type": "base64", "media_type": mediaType,
                                "data": imageData.base64EncodedString()]],
                    ["type": "text",
                     "text": "This is a screenshot taken during a video call. Extract the visible participant roster."],
                ],
            ]],
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 45

        let (data, response) = try await uploadBody(URLSession.shared, for: request, body: bodyData)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? ""
            throw RosterError.api((response as? HTTPURLResponse)?.statusCode ?? 0, message)
        }
        AIUsageLog.recordResponse(provider: "anthropic", model: model, source: "roster", data: data)
        return try Self.parse(from: data)
    }

    static func parse(from data: Data) throws -> MeetingRoster {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let toolUse = content.first(where: { ($0["type"] as? String) == "tool_use" }),
              let input = toolUse["input"] else {
            throw RosterError.noToolUse
        }
        let inputData = try JSONSerialization.data(withJSONObject: input)
        struct Wire: Decodable {
            var isVideoCall: Bool
            var participants: [String]
            var activeSpeaker: String?
        }
        let wire = try JSONDecoder().decode(Wire.self, from: inputData)
        guard wire.isVideoCall else { return MeetingRoster(participants: []) }
        let cleaned = wire.participants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return MeetingRoster(participants: cleaned, activeSpeaker: wire.activeSpeaker)
    }

    public enum RosterError: Error, LocalizedError {
        case api(Int, String)
        case noToolUse

        public var errorDescription: String? {
            switch self {
            case .api(let status, let message): return "Roster read failed (HTTP \(status)): \(message)"
            case .noToolUse: return "Couldn't parse the roster response"
            }
        }
    }
}
