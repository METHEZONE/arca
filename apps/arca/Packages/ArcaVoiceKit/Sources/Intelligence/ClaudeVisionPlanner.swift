import Foundation
import ArcaVoiceCore

/// What ARCA proposes after reading a screenshot or shared image.
public struct CapturePlan: Sendable, Codable {
    public var title: String
    /// What the image is about + why it matters, markdown.
    public var insightMarkdown: String
    public var actionItems: [MeetingNotes.ActionItem]
    /// One-line pitch ARCA uses when offering the plan ("회의 일정 3건을 캘린더 초안으로 만들까요?").
    public var offerLine: String

    public init(title: String, insightMarkdown: String,
                actionItems: [MeetingNotes.ActionItem], offerLine: String) {
        self.title = title
        self.insightMarkdown = insightMarkdown
        self.actionItems = actionItems
        self.offerLine = offerLine
    }
}

/// Reads an image with Claude vision and produces an action plan.
/// Same Messages API + forced-tool pattern as ClaudeSummarizer.
public struct ClaudeVisionPlanner: Sendable {
    /// Optional bring-up trace sink (set by the app). Nil in production.
    public nonisolated(unsafe) static var trace: (@Sendable (String) -> Void)?

    private let apiKey: String
    private let model: String
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public init(apiKey: String, model: String = "claude-sonnet-5") {
        self.apiKey = apiKey
        self.model = model
    }

    public func plan(imageURL: URL, context: String? = nil) async throws -> CapturePlan {
        let data = try Data(contentsOf: imageURL)
        guard data.count < 5 * 1024 * 1024 * 3 / 4 else {
            throw VisionError.imageTooLarge
        }
        let mediaType = Self.mediaType(for: imageURL)
        return try await plan(imageData: data, mediaType: mediaType, context: context)
    }

    /// Text/URL variant: same structured plan tool, no image.
    public func planText(_ text: String) async throws -> CapturePlan {
        let userText = "Read the following content, figure out what it is, and create an actionable action plan. Write it in English.\n\n\(text)"
        return try await run(content: [["type": "text", "text": userText]])
    }

    public func plan(imageData: Data, mediaType: String, context: String? = nil) async throws -> CapturePlan {
        Self.trace?("plan() entered, image=\(imageData.count) bytes")
        var userText = "Read this image, figure out what it is, and create an actionable action plan. Accurately extract the text, schedule, to-dos, and numbers on screen, and write it in English."
        if let context, !context.isEmpty {
            userText += "\n\nAdditional context: \(context)"
        }
        return try await run(content: [
            ["type": "image",
             "source": ["type": "base64", "media_type": mediaType, "data": imageData.base64EncodedString()]],
            ["type": "text", "text": userText],
        ])
    }

    private func run(content: [[String: Any]]) async throws -> CapturePlan {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let tool: [String: Any] = [
            "name": "record_capture_plan",
            "description": "Record the analysis and action plan for the image.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "A short title summarizing the image content, in English"],
                    "insightMarkdown": ["type": "string", "description": "What the image is and why it matters — extract the key information, in English markdown"],
                    "offerLine": ["type": "string", "description": "One line to offer to the user (e.g. 'I organized 3 to-dos into an action plan')"],
                    "actionItems": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "text": ["type": "string"],
                                "assigneeName": ["type": "string"],
                            ],
                            "required": ["text"],
                        ],
                    ],
                ],
                "required": ["title", "insightMarkdown", "offerLine", "actionItems"],
            ] as [String: Any],
        ]

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": "record_capture_plan"],
            "messages": [[
                "role": "user",
                "content": content,
            ]],
        ]
        // Send the body via uploadBody — data(for:) with a large httpBody can
        // hang over HTTP/2. See uploadBody for the transport choice.
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60
        Self.trace?("request built, body=\(bodyData.count) bytes; sending")

        let (data, response) = try await uploadBody(URLSession.shared, for: request, body: bodyData)
        Self.trace?("response received: \(data.count) bytes")

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? ""
            throw VisionError.api((response as? HTTPURLResponse)?.statusCode ?? 0, message)
        }
        return try Self.parsePlan(from: data)
    }

    static func parsePlan(from data: Data) throws -> CapturePlan {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let toolUse = content.first(where: { ($0["type"] as? String) == "tool_use" }),
              let input = toolUse["input"] else {
            throw VisionError.noToolUse
        }
        let inputData = try JSONSerialization.data(withJSONObject: input)
        struct Wire: Decodable {
            var title: String
            var insightMarkdown: String
            var offerLine: String
            struct Item: Decodable { var text: String; var assigneeName: String? }
            var actionItems: [Item]
        }
        let wire = try JSONDecoder().decode(Wire.self, from: inputData)
        return CapturePlan(
            title: wire.title,
            insightMarkdown: wire.insightMarkdown,
            actionItems: wire.actionItems.map { MeetingNotes.ActionItem(text: $0.text, assigneeName: $0.assigneeName) },
            offerLine: wire.offerLine)
    }

    public static func mediaType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }

    public enum VisionError: Error, LocalizedError {
        case imageTooLarge
        case api(Int, String)
        case noToolUse

        public var errorDescription: String? {
            switch self {
            case .imageTooLarge: return "Image is too large (5MB limit)"
            case .api(let status, let message): return "Image analysis failed (HTTP \(status)): \(message)"
            case .noToolUse: return "Couldn't parse the image analysis response"
            }
        }
    }
}
