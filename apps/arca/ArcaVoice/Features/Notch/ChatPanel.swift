#if os(macOS)
import SwiftUI
import ArcaVoiceKit

/// The conversation surface that drops out of the notch — ARCA's "mouth" open,
/// talking with you about what's on screen.
struct ChatPanel: View {
    @Bindable var chat: ChatSession
    var onClose: () -> Void
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.1))
            messages
            if let task = chat.proposedBrowserTask, !chat.codexRunning {
                browserOffer(task)
            }
            inputBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var header: some View {
        HStack(spacing: 8) {
            miniFace
            Text("ARCA")
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
            if chat.isThinking {
                ProgressView().controlSize(.mini).tint(.white)
            }
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 24, height: 24)
                    .background(.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.arcaPress)
        }
        .padding(.vertical, 8)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(chat.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: chat.messages.last?.parts.last?.text) {
                if let id = chat.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func browserOffer(_ task: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .foregroundStyle(.green)
            Text(task)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
            Spacer()
            Button(L("브라우저에서 실행", "Run in browser")) { chat.runProposedBrowserTask() }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.small)
        }
        .padding(10)
        .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(.bottom, 6)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(L("ARCA에게 물어보기…", "Ask ARCA…"), text: $chat.draftText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
                .focused($inputFocused)
                .onSubmit { chat.send() }
            Button {
                chat.send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(chat.draftText.isEmpty ? .white.opacity(0.3) : ArcaFace.ember)
            }
            .buttonStyle(.arcaPress)
            .disabled(chat.draftText.isEmpty || chat.isThinking)
        }
        .onAppear { inputFocused = true }
    }

    private var miniFace: some View {
        HStack(spacing: 5) {
            ForEach(0..<2, id: \.self) { _ in
                Capsule()
                    .fill(.white)
                    .frame(width: 8, height: 4)
                    .rotationEffect(.degrees(0))
            }
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    var body: some View {
        ChatBubbleView(message: message, compact: true, showFace: false)
    }
}
#endif
