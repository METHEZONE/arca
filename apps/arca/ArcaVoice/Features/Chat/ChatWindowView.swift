#if os(macOS)
import SwiftUI
import SwiftData
import ArcaVoiceKit

/// The chat, on its own. Opened from the floating ARCA or the menu; keeps one
/// running conversation per day so the window can be closed and reopened
/// without losing the thread, and shows up in the home's chat list like any
/// other conversation.
struct ChatWindowView: View {
    @Environment(\.modelContext) private var context
    @State private var chat: ChatSession
    @State private var restored = false

    init() {
        let day = MeetingNoteMarkdown.dayString(from: .now)
        _chat = State(initialValue: ChatSession(conversationId: "window-\(day)"))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ArcaFace(mood: chat.isThinking ? .thinking : .idle, size: 30, halo: false)
                    .frame(width: 34, height: 34)
                Text(HatchedCompanion.load()?.name ?? "ARCA")
                    .font(.system(.headline, design: .rounded, weight: .bold))
                Spacer()
                Button {
                    BrowserAgentWindow.present()
                } label: {
                    Label(L("브라우저", "Browser"), systemImage: "globe")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.arcaPress)
                .foregroundStyle(.white.opacity(0.7))
                .help(L("ARCA가 직접 쓰는 브라우저 창. 로그인은 여기서 한 번만.", "The browser ARCA drives. Sign in once here."))
                Button {
                    chat.endConversation()
                    chat = ChatSession()
                } label: {
                    Label(L("새 대화", "New chat"), systemImage: "plus.bubble")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.arcaPress)
                .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 18).padding(.vertical, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if chat.messages.isEmpty {
                            VStack(spacing: 8) {
                                ArcaFace(mood: .happy, size: 90, interactive: true)
                                Text(L("무엇이든 말해보세요 — 회의 요약, 오늘 할 일, 기억 찾기.", "Ask anything — meeting notes, today's to-dos, a memory."))
                                    .font(.callout).foregroundStyle(.white.opacity(0.5))
                            }
                            .padding(.top, 60)
                        }
                        ForEach(chat.messages) { message in
                            ChatBubbleView(message: message, compact: true, onSaveNote: { text in
                                _ = try? ChatToolbox.saveNote(title: String(text.prefix(40)), markdown: text)
                            })
                            .id(message.id)
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 8)
                }
                .onChange(of: chat.messages.last?.parts.count) { _, _ in
                    guard let id = chat.messages.last?.id else { return }
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }

            HStack(spacing: 10) {
                TextField(L("무엇을 도와드릴까요?", "What would you like to do?"), text: $chat.draftText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .rounded))
                    .lineLimit(1...6)
                    .onSubmit { chat.send() }
                Button { chat.send() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(chat.draftText.isEmpty ? .white.opacity(0.25) : ArcaSkins.current.mid)
                }
                .buttonStyle(.plain)
                .disabled(chat.draftText.trimmingCharacters(in: .whitespaces).isEmpty || chat.isThinking)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 14).padding(.bottom, 14)
        }
        .frame(minWidth: 440, minHeight: 520)
        .background(Color(red: 0.03, green: 0.05, blue: 0.09).ignoresSafeArea())
        .foregroundStyle(.white)
        .onAppear {
            guard !restored else { return }
            restored = true
            let id = chat.conversationId
            let entries = (try? context.fetch(FetchDescriptor<ChatLogEntry>(
                predicate: #Predicate { $0.conversationId == id }, sortBy: [SortDescriptor(\.createdAt)]))) ?? []
            if !entries.isEmpty { chat.restore(from: entries) }
        }
        .onDisappear { chat.endConversation() }
    }
}
#endif
