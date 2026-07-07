#if os(iOS)
import SwiftUI
import SwiftData
import ArcaVoiceKit

/// ARCA chat on iPhone — the same companion that lives in the Mac's notch.
/// Persisted history on top (ChatLogEntry, shared with the Mac dashboard once
/// sync lands), the live conversation below, memory injected every turn.
struct ChatTabView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ChatLogEntry.createdAt, order: .forward) private var log: [ChatLogEntry]
    @State private var chat = ChatSession()
    @State private var voice = VoiceTalk()
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                conversationRail
                messages
                if voice.isListening {
                    listeningBar
                }
                inputBar
            }
            .navigationTitle("ARCA")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        startNewChat()
                    } label: {
                        Label("New chat", systemImage: "plus.bubble")
                    }
                }
            }
        }
        .onDisappear {
            voice.stopSpeaking()
            chat.endConversation()
        }
        // Speak replies aloud while in a voice back-and-forth.
        .onChange(of: chat.messages.last?.id) {
            guard voice.voiceRepliesOn, !chat.isThinking,
                  let last = chat.messages.last, last.role == .assistant else { return }
            voice.speak(last.displayText)
        }
        // arca://talk (island / Action Button) drops straight into voice.
        .onReceive(NotificationCenter.default.publisher(for: .arcaOpenTalk)) { _ in
            Task { await beginVoiceTurn() }
        }
    }

    private var conversations: [ConversationSummary] {
        let grouped = Dictionary(grouping: log) { $0.conversationId }
        return grouped.compactMap { id, entries in
            guard let last = entries.max(by: { $0.createdAt < $1.createdAt }) else { return nil }
            let title = entries.first(where: { $0.roleRaw == "user" && !$0.text.isEmpty })?.text
                ?? last.text
            return ConversationSummary(
                id: id,
                title: title.isEmpty ? "Untitled chat" : String(title.prefix(48)),
                lastAt: last.createdAt,
                count: entries.count
            )
        }
        .sorted { $0.lastAt > $1.lastAt }
    }

    private var activeLog: [ChatLogEntry] {
        log.filter { $0.conversationId == chat.conversationId }
    }

    @ViewBuilder
    private var conversationRail: some View {
        if !conversations.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(conversations) { conversation in
                        Button {
                            openConversation(conversation.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(conversation.title)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                HStack(spacing: 3) {
                                    Text("\(conversation.count) turns ·")
                                    Text(conversation.lastAt, style: .relative)
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(maxWidth: 160, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(conversation.id == chat.conversationId
                                          ? ArcaFace.ember.opacity(0.18)
                                          : Color.secondary.opacity(0.10))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.bar)
        }
    }

    // MARK: - Voice turn

    private func beginVoiceTurn() async {
        voice.voiceRepliesOn = true
        await voice.startListening()
    }

    private func endVoiceTurn() {
        let text = voice.stopListening()
        guard !text.isEmpty else { return }
        chat.draftText = text
        chat.send()
    }

    private var listeningBar: some View {
        HStack(spacing: 10) {
            ArcaFace(mood: .listening, size: 34, halo: false)
            Text(voice.liveTranscript.isEmpty ? "Listening…" : voice.liveTranscript)
                .font(.subheadline)
                .foregroundStyle(voice.liveTranscript.isEmpty ? .secondary : .primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                endVoiceTurn()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(ArcaFace.ember)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(ArcaFace.ember.opacity(0.1))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    // Earlier conversations (persisted) — dimmed context.
                    if chat.messages.isEmpty {
                        ForEach(activeLog.suffix(30)) { entry in
                            HistoryBubble(entry: entry)
                        }
                    }
                    ForEach(chat.messages) { message in
                        LiveBubble(message: message).id(message.id)
                    }
                    if chat.isThinking {
                        HStack(spacing: 8) {
                            ArcaFace(mood: .thinking, size: 20, halo: false)
                                .frame(width: 22, height: 22)
                            ProgressView().controlSize(.small)
                        }
                        .padding(.leading, 4)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .onChange(of: chat.messages.last?.parts.last?.text) {
                if let id = chat.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            .overlay {
                if chat.messages.isEmpty && activeLog.isEmpty {
                    ContentUnavailableView(
                        "Talk to ARCA",
                        systemImage: "bubble.left.and.text.bubble.right",
                        description: Text("Ask anything — ARCA remembers what matters.")
                    )
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            // Voice turn: tap to talk, tap the ember arrow (or here) to send.
            Button {
                if voice.isListening {
                    endVoiceTurn()
                } else {
                    Task { await beginVoiceTurn() }
                }
            } label: {
                Image(systemName: voice.isListening ? "waveform.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(voice.isListening ? ArcaFace.ember : Color.secondary)
                    .symbolEffect(.pulse, isActive: voice.isListening)
            }
            TextField("Ask ARCA…", text: $chat.draftText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
                .focused($inputFocused)
                .onSubmit { chat.send() }
            Button {
                voice.voiceRepliesOn = false
                chat.send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(chat.draftText.isEmpty ? Color.secondary : ArcaFace.ember)
            }
            .disabled(chat.draftText.isEmpty || chat.isThinking)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func startNewChat() {
        chat.endConversation()
        chat = ChatSession()
        inputFocused = true
    }

    private func openConversation(_ id: String) {
        guard id != chat.conversationId else { return }
        chat.endConversation()
        let next = ChatSession(conversationId: id)
        next.restore(from: log.filter { $0.conversationId == id })
        chat = next
        voice.stopSpeaking()
    }
}

private struct HistoryBubble: View {
    let entry: ChatLogEntry
    private var isUser: Bool { entry.roleRaw == "user" }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            Text(entry.text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(
                    isUser ? AnyShapeStyle(ArcaTheme.idle.opacity(0.25)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                    in: RoundedRectangle(cornerRadius: 14))
            if !isUser { Spacer(minLength: 40) }
        }
    }

}

private struct ConversationSummary: Identifiable {
    let id: String
    let title: String
    let lastAt: Date
    let count: Int
}

private struct LiveBubble: View {
    let message: ChatMessage
    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                ForEach(Array(message.parts.enumerated()), id: \.offset) { _, part in
                    switch part.kind {
                    case .image:
                        if let data = part.imageData, let ui = UIImage(data: data) {
                            Image(uiImage: ui)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 220, maxHeight: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    case .text:
                        Text(LocalizedStringKey(part.text ?? ""))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .foregroundStyle(isUser ? .white : .primary)
                            .background(
                                isUser ? AnyShapeStyle(ArcaTheme.idle) : AnyShapeStyle(.quaternary),
                                in: RoundedRectangle(cornerRadius: 14))
                            .textSelection(.enabled)
                    }
                }
            }
            if !isUser { Spacer(minLength: 40) }
        }
    }
}
#endif
