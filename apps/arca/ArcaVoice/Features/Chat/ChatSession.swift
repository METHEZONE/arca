import Foundation
import SwiftData
import ArcaVoiceKit

/// A live conversation with ARCA — anchored in the Mac's notch or the iPhone
/// chat tab. Holds the message history, drives Claude turns with long-term
/// memory injected, and (on macOS) can delegate browser tasks to Codex.
@MainActor
@Observable
final class ChatSession {
    let conversationId: String
    private(set) var messages: [ChatMessage] = []
    private(set) var isThinking = false
    /// A browser task ARCA proposed and is waiting to run (nil = none pending).
    private(set) var proposedBrowserTask: String?
    private(set) var codexRunning = false
    var draftText: String = ""
    /// Guards duplicate memory extraction when a chat surface closes twice.
    @ObservationIgnored private var memoriesExtracted = false
    @ObservationIgnored private var hasNewTurns = false

    init(conversationId: String = UUID().uuidString) {
        self.conversationId = conversationId
    }

    func restore(from entries: [ChatLogEntry]) {
        messages = entries.map { entry in
            var parts: [ChatMessage.Part] = []
            if let data = entry.imageData {
                parts.append(.image(data))
            }
            if !entry.text.isEmpty {
                parts.append(.text(entry.text))
            }
            if parts.isEmpty {
                parts.append(.text(" "))
            }
            return ChatMessage(
                role: entry.roleRaw == "user" ? .user : .assistant,
                parts: parts
            )
        }
        draftText = ""
        isThinking = false
        proposedBrowserTask = nil
        codexRunning = false
        memoriesExtracted = false
        hasNewTurns = false
    }

    /// Seeds the conversation with an image (a dragged or captured screenshot).
    func begin(withImage data: Data, mediaType: String = "image/jpeg", prompt: String? = nil) {
        messages = []
        var parts: [ChatMessage.Part] = [.image(data, mediaType: mediaType)]
        parts.append(.text(prompt ?? "I'm looking at this screen. Tell me what you see and what I should do. I'll ask follow-up questions after this."))
        let userMessage = ChatMessage(role: .user, parts: parts)
        messages.append(userMessage)
        hasNewTurns = true
        persist(role: "user", text: prompt ?? "Asked about this screen", imageData: data)
        runTurn()
    }

    /// Sends the user's typed follow-up.
    func send() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }
        draftText = ""
        messages.append(ChatMessage(role: .user, parts: [.text(text)]))
        hasNewTurns = true
        persist(role: "user", text: text)
        runTurn()
    }

    /// Appends a turn to the persisted chat log so every surface (Mac
    /// dashboard, iPhone tab) shows the same history.
    private func persist(role: String, text: String, imageData: Data? = nil) {
        guard let context = AppServices.shared.container?.mainContext else { return }
        context.insert(ChatLogEntry(role: role, text: text, conversationId: conversationId, imageData: imageData))
        try? context.save()
    }

    // MARK: - Long-term memory

    private func memoryFacts() -> [MemoryFact] {
        guard let context = AppServices.shared.container?.mainContext else { return [] }
        let all = (try? context.fetch(FetchDescriptor<MemoryFact>())) ?? []
        return all
    }

    /// Call when the chat surface closes — distills the conversation into
    /// durable memories (skips trivial exchanges; needs an Anthropic key).
    func endConversation() {
        guard !memoriesExtracted else { return }
        guard hasNewTurns else { return }
        // Nothing worth remembering in a one-sided or empty exchange.
        guard messages.count >= 2 else { return }
        memoriesExtracted = true
        guard let key = KeychainStore.get(.anthropic), !key.isEmpty else { return }
        let transcript = messages
            .map { "\($0.role == .user ? "User" : "ARCA"): \($0.displayText)" }
            .joined(separator: "\n")
        let known = memoryFacts().map(\.text)
        let model = UserDefaults.standard.string(forKey: "chatModel") ?? "claude-sonnet-5"
        Task { @MainActor in
            guard let extracted = try? await MemoryExtractor(apiKey: key, model: model)
                .extract(fromConversation: transcript, knownFacts: known),
                  !extracted.isEmpty,
                  let context = AppServices.shared.container?.mainContext else { return }
            for memory in extracted {
                context.insert(MemoryFact(text: memory.text, kind: memory.kind, source: "chat"))
            }
            try? context.save()
        }
    }

    private func runTurn() {
        let anthropicKey = KeychainStore.get(.anthropic)
        let openAIKey = KeychainStore.get(.openAI)
        guard anthropicKey?.isEmpty == false || openAIKey?.isEmpty == false else {
            appendAssistant("An OpenAI or Anthropic key is required — add one in Settings.")
            return
        }
        isThinking = true
        proposedBrowserTask = nil
        let model = UserDefaults.standard.string(forKey: "chatModel") ?? "claude-sonnet-5"
        let history = messages
        let memoryBlock = MemoryPrompt.systemBlock(facts: memoryFacts())
        Task { @MainActor in
            do {
                let raw: String
                if let apiKey = anthropicKey, !apiKey.isEmpty {
                    do {
                        raw = try await ClaudeChat(apiKey: apiKey, model: model,
                                                   extraSystem: memoryBlock).reply(to: history)
                    } catch {
                        guard let apiKey = openAIKey, !apiKey.isEmpty else { throw error }
                        raw = try await OpenAIChat(apiKey: apiKey).reply(to: history)
                    }
                } else if let apiKey = openAIKey, !apiKey.isEmpty {
                    raw = try await OpenAIChat(apiKey: apiKey).reply(to: history)
                } else {
                    raw = "An OpenAI or Anthropic key is required."
                }
                let visible = ClaudeChat.stripBrowserTag(raw)
                appendAssistant(visible.isEmpty ? "(No response)" : visible)
                #if os(macOS)
                proposedBrowserTask = ClaudeChat.browserTask(in: raw)
                #endif
            } catch {
                appendAssistant(error.localizedDescription)
            }
            isThinking = false
        }
    }

    private func appendAssistant(_ text: String) {
        messages.append(ChatMessage(role: .assistant, parts: [.text(text)]))
        persist(role: "assistant", text: text)
    }

    // MARK: - Codex browser delegation (Mac only)

    #if os(macOS)
    func runProposedBrowserTask() {
        guard let task = proposedBrowserTask, !codexRunning else { return }
        proposedBrowserTask = nil
        codexRunning = true
        messages.append(ChatMessage(role: .assistant, parts: [.text("🌐 I'll run this in the browser: \(task)")]))
        let progressID = UUID()
        messages.append(ChatMessage(id: progressID, role: .assistant, parts: [.text("…")], isPending: true))

        Task { @MainActor in
            var log = ""
            for await line in CodexBridge.run(task: task) {
                log += (log.isEmpty ? "" : "\n") + line
                if let index = messages.firstIndex(where: { $0.id == progressID }) {
                    messages[index].parts = [.text(String(log.suffix(1200)))]
                }
            }
            if let index = messages.firstIndex(where: { $0.id == progressID }) {
                messages[index].isPending = false
                if messages[index].displayText.trimmingCharacters(in: .whitespaces) == "…" {
                    messages[index].parts = [.text("Done.")]
                }
            }
            codexRunning = false
        }
    }
    #endif
}
