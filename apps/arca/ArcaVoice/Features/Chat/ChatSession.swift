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
    /// Extra grounding that rides every turn's system prompt — e.g. the full
    /// meeting record when this chat is scoped to one session.
    @ObservationIgnored private var contextBlock: String?

    init(conversationId: String = UUID().uuidString) {
        self.conversationId = conversationId
        // Server memory is fetched once per conversation, off the turn path;
        // turns read the cache so a slow network never delays a reply.
        if BrainClient.isAvailable {
            Task.detached(priority: .utility) { await BrainClient.refreshContext() }
        }
    }

    /// Scopes this conversation to a specific record (a meeting, a day log…):
    /// the block is injected into the system prompt on every turn.
    func attachContext(_ block: String) {
        contextBlock = block
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
        guard let key = ArcaCloud.anthropicKey, !key.isEmpty else { return }
        let transcript = messages
            .map { "\($0.role == .user ? "User" : "ARCA"): \($0.displayText)" }
            .joined(separator: "\n")
        let known = MemoryPrompt.knownFactsForDedup(memoryFacts())
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
            await BrainClient.remember(extracted.map {
                BrainEntry(text: $0.text, kind: $0.kind, source: "chat", sourceRef: conversationId)
            })
        }
    }

    private func runTurn() {
        let anthropicKey = ArcaCloud.anthropicKey
        let openAIKey = KeychainStore.get(.openAI)
        guard anthropicKey?.isEmpty == false || openAIKey?.isEmpty == false else {
            appendAssistant(L("OpenAI 또는 Anthropic 키가 필요해요 — 설정에서 추가해 주세요.",
                              "An OpenAI or Anthropic key is required — add one in Settings."))
            return
        }
        isThinking = true
        proposedBrowserTask = nil
        let model = UserDefaults.standard.string(forKey: "chatModel") ?? "claude-sonnet-5"
        let history = messages
        var memoryBlock = MemoryPrompt.systemBlock(facts: memoryFacts(), brain: BrainClient.cachedContext)
        // Today's measured body rides every turn, so "지금 컨디션 어때?" is answered
        // from Apple Health instead of guessed at. Empty when nothing's measured.
        memoryBlock += VitalsEngine.shared.chatContextBlock()
        if let contextBlock {
            memoryBlock = "\n\n" + contextBlock + memoryBlock
        }

        // The live assistant turn: thoughts, tool steps and text stream into
        // this one message as they arrive, then it's finalized.
        let liveID = UUID()
        messages.append(ChatMessage(id: liveID, role: .assistant, parts: [], isPending: true))

        Task { @MainActor in
            do {
                let raw: String
                if let apiKey = anthropicKey, !apiKey.isEmpty {
                    do {
                        raw = try await runClaudeAgent(apiKey: apiKey, model: model, system: memoryBlock,
                                                       history: history, liveID: liveID)
                    } catch {
                        guard let apiKey = openAIKey, !apiKey.isEmpty else { throw error }
                        raw = try await OpenAIChat(apiKey: apiKey).reply(to: history)
                    }
                } else if let apiKey = openAIKey, !apiKey.isEmpty {
                    raw = try await OpenAIChat(apiKey: apiKey).reply(to: history)
                } else {
                    raw = L("OpenAI 또는 Anthropic 키가 필요해요.", "An OpenAI or Anthropic key is required.")
                }
                let visible = ClaudeChat.stripActionTags(raw)
                finalizeLive(id: liveID, text: visible.isEmpty ? L("(응답 없음)", "(No response)") : visible)
                #if os(macOS)
                proposedBrowserTask = ClaudeChat.browserTask(in: raw)
                #endif
                // Calendar actions run immediately — the user already asked;
                // asking again ("shall I add it?") is the failure mode.
                if let draft = ClaudeChat.calendarDraft(in: raw) {
                    await createCalendarEvent(from: draft)
                }
                // Email is external-risk (OpenWorker-style gate): send now at
                // the user's trust level, otherwise queue a one-tap approval.
                if let email = ClaudeChat.emailDraft(in: raw) {
                    await handleEmailAction(email)
                }
                // Food is zero-risk and purely additive — logging it needs no
                // gate. The user already told us what they ate.
                if let meal = ClaudeChat.mealDraft(in: raw) {
                    await logMeal(meal)
                }
            } catch {
                finalizeLive(id: liveID, text: UserFacingError.message(for: error))
            }
            isThinking = false
        }
    }

    /// Streams one Claude turn with thinking and tools into the live message.
    private func runClaudeAgent(apiKey: String, model: String, system: String,
                                history: [ChatMessage], liveID: UUID) async throws -> String {
        let agent = ClaudeAgent(apiKey: apiKey, model: model)
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd (EEEE) HH:mm"
        let dateBlock = "\nRight now it is \(dateFormatter.string(from: Date())) in the user's time zone (\(TimeZone.current.identifier))."
        let fullSystem = ClaudeChat.systemPrompt + dateBlock + system

        return try await agent.turn(
            system: fullSystem,
            history: history,
            tools: ChatToolbox.specs,
            webSearch: true,
            execute: { name, inputJSON in
                await ChatToolbox.execute(name: name, inputJSON: inputJSON)
            },
            onEvent: { event in
                Task { @MainActor in self.apply(event, to: liveID) }
            })
    }

    private func apply(_ event: ClaudeAgentEvent, to liveID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == liveID }) else { return }
        var parts = messages[index].parts
        switch event {
        case .thinking(let delta):
            if let last = parts.indices.last, parts[last].kind == .thought {
                parts[last].text = (parts[last].text ?? "") + delta
            } else {
                parts.append(.thought(delta))
            }
        case .text(let delta):
            if let last = parts.indices.last, parts[last].kind == .text {
                parts[last].text = (parts[last].text ?? "") + delta
            } else {
                parts.append(.text(delta))
            }
        case .toolStarted(_, let name, let inputJSON):
            parts.append(.tool(name, summary: ChatToolbox.label(for: name, inputJSON: inputJSON), status: .running))
        case .toolFinished(_, let name, let summary, let ok):
            if let running = parts.lastIndex(where: { $0.kind == .tool && $0.toolName == name && $0.toolStatus == .running }) {
                parts[running].text = summary
                parts[running].toolStatus = ok ? .done : .failed
            }
        case .webSearch(let query):
            parts.append(.tool("web_search", summary: L("웹 검색: \(query)", "Web search: \(query)"), status: .done))
        case .finished:
            break
        }
        messages[index].parts = parts
    }

    /// Replaces the streamed text with the cleaned final text (action tags
    /// stripped), keeps the thoughts and tool steps, and persists the words.
    private func finalizeLive(id: UUID, text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            appendAssistant(text)
            return
        }
        var parts = messages[index].parts.filter { $0.kind != .text }
        parts.append(.text(text))
        messages[index].parts = parts
        messages[index].isPending = false
        persist(role: "assistant", text: text)
        CompanionProgress.shared.award(.chatTurn)
        for part in messages[index].parts where part.kind == .tool && part.toolStatus == .done {
            switch part.toolName {
            case "save_note": CompanionProgress.shared.award(.noteSaved)
            case "run_browser_task": CompanionProgress.shared.award(.browserTask)
            default: break
            }
        }
    }

    private func appendAssistant(_ text: String) {
        messages.append(ChatMessage(role: .assistant, parts: [.text(text)]))
        persist(role: "assistant", text: text)
        // Chat is the only thing the trial balance pays for — recording and
        // transcription are unlimited. Billed on the reply rather than the
        // send, so a request that failed before reaching the model is free.
        TrialCredit.consumeChatMessage()
    }

    /// Executes or queues an `[EMAIL: …]` action, gated by declared action
    /// risk vs the user's autonomy level (ActionRisk, ported from OpenWorker).
    private func handleEmailAction(_ draft: EmailActionDraft) async {
        if ChatAction.email.allowedWithoutApproval(at: AutonomyLevel.current) {
            guard let sender = ComposioEmailSender.fromArcaConfig() else {
                appendAssistant("⚠️ Gmail 연결이 없어 보낼 수 없었어요 — 커넥터에서 Gmail을 연결해 주세요.")
                return
            }
            do {
                try await sender.send(to: draft.to, subject: draft.subject,
                                      htmlBody: draft.htmlBody)
                appendAssistant("📤 보냈어요 — \(draft.to), \"\(draft.subject)\"")
            } catch {
                appendAssistant("⚠️ 이메일 발송 실패: \(UserFacingError.message(for: error))")
            }
        } else {
            // Below send autonomy: park it in the approval inbox (투두 레일의
            // 답장 대기) instead of silently dropping or nagging in chat.
            guard let context = AppServices.shared.container?.mainContext else { return }
            let proposal = ReplyProposal(
                source: "gmail", channel: draft.to,
                author: draft.to,
                original: "챗에서 작성: \(draft.subject)",
                draft: draft.body)
            proposal.subject = draft.subject
            context.insert(proposal)
            try? context.save()
            appendAssistant("✉️ 초안을 준비했어요 — \(draft.to), \"\(draft.subject)\". 투두 레일의 답장 대기에서 한 번에 승인하면 발송돼요. (자율도를 '루틴 처리+발송'으로 올리면 바로 보냅니다.)")
        }
    }

    /// Records a `[MEAL: …]` the model estimated.
    ///
    /// The reply already stated the estimate, so nothing is echoed on the happy
    /// path — a second "기록했어요" line under the model's own sentence is noise.
    /// Only the cases where the user's mental model would otherwise be wrong get
    /// a line: the Mac can't reach Apple Health at all, and a failed write needs
    /// to be admitted rather than silently retried.
    private func logMeal(_ draft: MealActionDraft) async {
        guard let entry = await VitalsEngine.shared.logMeal(draft) else { return }
        #if os(macOS)
        appendAssistant("🍽 기록했어요 — 애플 건강에는 아이폰이 다음 동기화에 반영합니다.")
        #else
        if !entry.writtenToHealth {
            appendAssistant("⚠️ 애플 건강에 바로 쓰지 못했어요 — ARCA에는 저장됐고, 다음 동기화에서 다시 시도합니다.")
        }
        #endif
    }

    /// Executes a `[CALENDAR: …]` action the model emitted and reports the
    /// outcome in the conversation. No confirmation round-trip by design.
    private func createCalendarEvent(from draft: CalendarEventDraft) async {
        guard let start = draft.startDate else {
            appendAssistant("⚠️ 캘린더 등록 실패: 시작 시간을 해석하지 못했어요 (\(draft.start))")
            return
        }
        do {
            try await CalendarEventCreator.create(
                title: draft.title,
                start: start,
                durationMinutes: draft.durationMinutes ?? 60,
                location: draft.location,
                description: draft.description ?? "")
            let when = start.formatted(.dateTime.month().day().weekday().hour().minute())
            appendAssistant("✅ 캘린더에 추가했어요 — \(draft.title), \(when)")
        } catch {
            appendAssistant("⚠️ 캘린더 등록 실패: \(UserFacingError.message(for: error))")
        }
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
