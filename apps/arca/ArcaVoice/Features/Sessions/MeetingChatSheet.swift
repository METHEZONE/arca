import SwiftUI
import SwiftData
import ArcaVoiceKit

/// "Chat about this" — a conversation scoped to one meeting record. The full
/// meeting (summary, decisions, action items, transcript) rides the system
/// prompt, and the thread persists per meeting so reopening continues it.
struct MeetingChatSheet: View {
    let session: RecordingSession

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var chat: ChatSession
    @FocusState private var inputFocused: Bool

    init(session: RecordingSession) {
        self.session = session
        _chat = State(initialValue: ChatSession(conversationId: "meeting-\(session.directoryName)"))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messages
            Divider()
            inputBar
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 480, idealHeight: 600)
        #endif
        .onAppear {
            let stored = (try? modelContext.fetch(FetchDescriptor<ChatLogEntry>()))?
                .filter { $0.conversationId == chat.conversationId }
                .sorted { $0.createdAt < $1.createdAt } ?? []
            if !stored.isEmpty {
                chat.restore(from: stored)
            }
            chat.attachContext(MeetingChatContext.block(for: session))
            inputFocused = true
        }
        .onDisappear {
            chat.endConversation()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ArcaFace(mood: .idle, size: 26, halo: false, alive: false)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Chat about this meeting")
                    .font(.headline)
                Text(session.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.arcaPress)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(chat.messages) { message in
                        MeetingChatBubble(message: message).id(message.id)
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
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: chat.messages.last?.parts.last?.text) {
                if let id = chat.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            .overlay {
                if chat.messages.isEmpty {
                    ContentUnavailableView(
                        "이 회의에 대해 물어보세요",
                        systemImage: "bubble.left.and.text.bubble.right",
                        description: Text("요약·결정사항·액션아이템·전사 전체를 알고 있어요.\n\"홍혜수님이 뭐라고 했지?\", \"팔로업 이메일 초안 써줘\" 같은 것들.")
                    )
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("이 회의에 대해 물어보기…", text: $chat.draftText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                .focused($inputFocused)
                .onSubmit { chat.send() }
            Button {
                chat.send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(chat.draftText.isEmpty ? Color.secondary : ArcaFace.ember)
            }
            .buttonStyle(.arcaPress)
            .disabled(chat.draftText.isEmpty || chat.isThinking)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct MeetingChatBubble: View {
    let message: ChatMessage
    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            Text(LocalizedStringKey(message.displayText))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(isUser ? .white : .primary)
                .background(
                    isUser ? AnyShapeStyle(ArcaTheme.idle) : AnyShapeStyle(.quaternary),
                    in: RoundedRectangle(cornerRadius: 14))
                .textSelection(.enabled)
            if !isUser { Spacer(minLength: 40) }
        }
    }
}

/// Builds the system-prompt grounding block for a meeting-scoped chat.
enum MeetingChatContext {
    static func block(for session: RecordingSession, transcriptCap: Int = 24_000) -> String {
        var lines: [String] = []
        lines.append("## The user is chatting about this meeting record")
        lines.append("Title: \(session.title)")
        lines.append("When: \(session.createdAt.formatted(.dateTime.year().month().day().hour().minute()))")
        if session.duration > 0 {
            lines.append("Duration: \(Int(session.duration / 60)) min")
        }
        if let app = session.meetingApp {
            lines.append("App: \(app)")
        }

        if let note = session.note {
            if let summary = note.summaryMarkdown, !summary.isEmpty {
                lines.append("\n### Summary\n\(summary)")
            }
            if let data = note.decisionsJSON,
               let decisions = try? JSONDecoder().decode([String].self, from: data),
               !decisions.isEmpty {
                lines.append("\n### Decisions\n" + decisions.map { "- \($0)" }.joined(separator: "\n"))
            }
            if let data = note.actionItemsJSON,
               let items = try? JSONDecoder().decode([MeetingNotes.ActionItem].self, from: data),
               !items.isEmpty {
                let rendered = items.map { item -> String in
                    var line = "- \(item.text)"
                    if let assignee = item.assigneeName { line += " (담당: \(assignee))" }
                    if let due = item.due { line += " (마감: \(due.formatted(.dateTime.month().day())))" }
                    return line
                }
                lines.append("\n### Action Items\n" + rendered.joined(separator: "\n"))
            }
            if let enhanced = note.enhancedMarkdown, !enhanced.isEmpty {
                lines.append("\n### User's Notes\n\(enhanced)")
            }
        }

        let transcript = session.segments
            .sorted { $0.start < $1.start }
            .map { segment -> String in
                let speaker = segment.speakerKey
                    ?? (segment.channelRaw == "microphone" ? "Me" : "Other")
                return "\(speaker): \(segment.text)"
            }
            .joined(separator: "\n")
        if !transcript.isEmpty {
            // Very long meetings: keep the opening and the ending, elide the
            // middle — the cap keeps token cost sane.
            let clipped: String
            if transcript.count > transcriptCap {
                let head = transcript.prefix(transcriptCap * 2 / 3)
                let tail = transcript.suffix(transcriptCap / 3)
                clipped = "\(head)\n[… 중간 생략 …]\n\(tail)"
            } else {
                clipped = transcript
            }
            lines.append("\n### Transcript\n\(clipped)")
        }

        lines.append("\nGround every answer in this record. Reply in the user's language.")
        return lines.joined(separator: "\n")
    }
}
