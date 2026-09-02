import Foundation
import ArcaVoiceCore

/// A tool ARCA can call during a chat turn. The schema is JSON text so the
/// spec stays `Sendable`; the app decides what each name does.
public struct ClaudeToolSpec: Sendable {
    public let name: String
    public let description: String
    public let schemaJSON: String

    public init(name: String, description: String, schemaJSON: String) {
        self.name = name
        self.description = description
        self.schemaJSON = schemaJSON
    }
}

/// What the streaming agent loop reports as it goes — enough for a chat
/// surface to show thinking as it forms, text as it arrives, and each tool
/// step as it starts and lands.
public enum ClaudeAgentEvent: Sendable {
    case thinking(String)
    case text(String)
    case toolStarted(id: String, name: String, inputJSON: String)
    case toolFinished(id: String, name: String, summary: String, ok: Bool)
    case webSearch(query: String)
    case finished(stopReason: String?)
}

/// Streaming, tool-using conversation turn over the Anthropic Messages API.
///
/// One `turn` may take several round trips: the model thinks, calls tools,
/// gets results, thinks again, and finally answers. Thinking blocks and their
/// signatures are carried back verbatim on every round, as the API requires.
/// Web search is the server-side tool, so it needs no executor.
public struct ClaudeAgent: Sendable {
    public typealias ToolExecutor = @Sendable (_ name: String, _ inputJSON: String) async -> (summary: String, result: String, ok: Bool)

    private let apiKey: String
    private let model: String
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    /// Runs one user turn to completion. Returns the final visible text.
    public func turn(
        system: String,
        history: [ChatMessage],
        tools: [ClaudeToolSpec],
        webSearch: Bool,
        thinkingBudget: Int = 1600,
        maxRounds: Int = 6,
        execute: ToolExecutor,
        onEvent: @escaping @Sendable (ClaudeAgentEvent) -> Void
    ) async throws -> String {
        var wireMessages: [[String: Any]] = history.map(ClaudeChat.wireMessage)
        var finalText = ""

        for _ in 0..<maxRounds {
            let round = try await streamRound(system: system, messages: wireMessages, tools: tools,
                                              webSearch: webSearch, thinkingBudget: thinkingBudget,
                                              onEvent: onEvent)
            finalText += round.text
            wireMessages.append(["role": "assistant", "content": round.assistantContent])

            let calls = round.toolCalls
            guard round.stopReason == "tool_use", !calls.isEmpty else {
                onEvent(.finished(stopReason: round.stopReason))
                return finalText
            }

            var results: [[String: Any]] = []
            for call in calls {
                let outcome = await execute(call.name, call.inputJSON)
                onEvent(.toolFinished(id: call.id, name: call.name, summary: outcome.summary, ok: outcome.ok))
                results.append([
                    "type": "tool_result",
                    "tool_use_id": call.id,
                    "content": String(outcome.result.prefix(12_000)),
                    "is_error": !outcome.ok,
                ])
            }
            wireMessages.append(["role": "user", "content": results])
        }
        onEvent(.finished(stopReason: "max_rounds"))
        return finalText
    }

    // MARK: - One streamed API round

    struct ToolCall { let id: String; let name: String; let inputJSON: String }
    struct Round {
        var text = ""
        var assistantContent: [[String: Any]] = []
        var toolCalls: [ToolCall] = []
        var stopReason: String?
    }

    private func streamRound(
        system: String, messages: [[String: Any]], tools: [ClaudeToolSpec], webSearch: Bool,
        thinkingBudget: Int, onEvent: @escaping @Sendable (ClaudeAgentEvent) -> Void
    ) async throws -> Round {
        var toolDefs: [[String: Any]] = tools.compactMap { spec in
            guard let data = spec.schemaJSON.data(using: .utf8),
                  let schema = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return ["name": spec.name, "description": spec.description, "input_schema": schema]
        }
        if webSearch {
            toolDefs.append(["type": "web_search_20250305", "name": "web_search", "max_uses": 3])
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": max(thinkingBudget + 2500, 4000),
            "stream": true,
            "system": system,
            "messages": messages,
            "thinking": ["type": "enabled", "budget_tokens": thinkingBudget],
        ]
        if !toolDefs.isEmpty { body["tools"] = toolDefs }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // Lets the model think between tool calls, not only before the first one.
        request.setValue("interleaved-thinking-2025-05-14", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeChat.ChatError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            var errorText = ""
            for try await line in bytes.lines { errorText += line; if errorText.count > 600 { break } }
            throw ClaudeChat.ChatError.api(http.statusCode, String(errorText.prefix(300)))
        }

        // Content blocks under construction, by index.
        struct Block {
            var type: String
            var text = ""
            var thinking = ""
            var signature = ""
            var toolId = ""
            var toolName = ""
            var inputJSON = ""
            var raw: [String: Any] = [:]
        }
        var blocks: [Int: Block] = [:]
        var round = Round()

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { continue }

            switch type {
            case "content_block_start":
                guard let index = json["index"] as? Int,
                      let block = json["content_block"] as? [String: Any],
                      let blockType = block["type"] as? String else { continue }
                var entry = Block(type: blockType, raw: block)
                if blockType == "tool_use" || blockType == "server_tool_use" {
                    entry.toolId = block["id"] as? String ?? ""
                    entry.toolName = block["name"] as? String ?? ""
                    if blockType == "tool_use" {
                        onEvent(.toolStarted(id: entry.toolId, name: entry.toolName, inputJSON: ""))
                    }
                }
                blocks[index] = entry
            case "content_block_delta":
                guard let index = json["index"] as? Int,
                      let delta = json["delta"] as? [String: Any],
                      let deltaType = delta["type"] as? String,
                      var entry = blocks[index] else { continue }
                switch deltaType {
                case "text_delta":
                    let text = delta["text"] as? String ?? ""
                    entry.text += text
                    onEvent(.text(text))
                case "thinking_delta":
                    let text = delta["thinking"] as? String ?? ""
                    entry.thinking += text
                    onEvent(.thinking(text))
                case "signature_delta":
                    entry.signature += delta["signature"] as? String ?? ""
                case "input_json_delta":
                    entry.inputJSON += delta["partial_json"] as? String ?? ""
                default: break
                }
                blocks[index] = entry
            case "content_block_stop":
                guard let index = json["index"] as? Int, let entry = blocks[index] else { continue }
                if entry.type == "server_tool_use", entry.toolName == "web_search" {
                    let query = (try? JSONSerialization.jsonObject(with: Data(entry.inputJSON.utf8)) as? [String: Any])?["query"] as? String
                    onEvent(.webSearch(query: query ?? ""))
                }
            case "message_delta":
                if let delta = json["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                    round.stopReason = reason
                }
            case "error":
                let message = (json["error"] as? [String: Any])?["message"] as? String ?? "stream error"
                throw ClaudeChat.ChatError.api(0, message)
            default:
                break
            }
        }

        // Rebuild the assistant content in order, exactly as the API wants it back.
        for index in blocks.keys.sorted() {
            guard let block = blocks[index] else { continue }
            switch block.type {
            case "text":
                round.text += block.text
                round.assistantContent.append(["type": "text", "text": block.text])
            case "thinking":
                var content: [String: Any] = ["type": "thinking", "thinking": block.thinking]
                if !block.signature.isEmpty { content["signature"] = block.signature }
                round.assistantContent.append(content)
            case "redacted_thinking":
                round.assistantContent.append(block.raw)
            case "tool_use":
                let input = (try? JSONSerialization.jsonObject(with: Data(block.inputJSON.utf8)) as? [String: Any]) ?? [:]
                round.assistantContent.append(["type": "tool_use", "id": block.toolId, "name": block.toolName, "input": input])
                round.toolCalls.append(ToolCall(id: block.toolId, name: block.toolName,
                                                inputJSON: block.inputJSON.isEmpty ? "{}" : block.inputJSON))
            case "server_tool_use":
                let input = (try? JSONSerialization.jsonObject(with: Data(block.inputJSON.utf8)) as? [String: Any]) ?? [:]
                round.assistantContent.append(["type": "server_tool_use", "id": block.toolId, "name": block.toolName, "input": input])
            default:
                // web_search_tool_result and anything new arrive whole in the start event.
                round.assistantContent.append(block.raw)
            }
        }
        return round
    }
}
