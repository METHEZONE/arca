import SwiftUI
import ArcaVoiceKit
#if os(macOS)
import AppKit
#endif

/// One message in any ARCA chat surface. Assistant turns can carry three
/// kinds of parts and each gets its own shape: thoughts in a cloud that
/// streams while ARCA is still thinking, tool steps as small status pills,
/// and the answer itself as rendered markdown with a "save as note" action.
struct ChatBubbleView: View {
    let message: ChatMessage
    var compact = false
    var showFace = true
    var onSaveNote: ((String) -> Void)? = nil

    @State private var thoughtsExpanded = false

    private var isUser: Bool { message.role == .user }
    private var thoughts: [String] { message.parts.filter { $0.kind == .thought }.compactMap(\.text) }
    private var tools: [ChatMessage.Part] { message.parts.filter { $0.kind == .tool } }
    private var texts: [String] { message.parts.filter { $0.kind == .text }.compactMap(\.text).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
    private var images: [Data] { message.parts.filter { $0.kind == .image }.compactMap(\.imageData) }
    private var stillThinking: Bool { message.isPending && texts.isEmpty }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isUser { Spacer(minLength: compact ? 40 : 80) }
            if !isUser, showFace {
                ArcaFace(mood: message.isPending ? .thinking : .idle, size: 28, halo: false, alive: false)
                    .frame(width: 32, height: 32)
            }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                ForEach(Array(images.enumerated()), id: \.offset) { _, data in
                    imageView(data)
                }
                if !isUser, !thoughts.isEmpty {
                    ThoughtCloud(text: thoughts.joined(), live: stillThinking, expanded: $thoughtsExpanded)
                }
                if !isUser, !tools.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                            ToolStepPill(part: tool)
                        }
                    }
                }
                ForEach(Array(texts.enumerated()), id: \.offset) { _, text in
                    textBubble(text)
                }
                if stillThinking, thoughts.isEmpty, tools.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L("생각 중…", "Thinking…")).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
            if !isUser { Spacer(minLength: compact ? 40 : 80) }
        }
        .padding(.horizontal, compact ? 0 : 28)
        .animation(.easeOut(duration: 0.2), value: message.parts.count)
    }

    private func textBubble(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if isUser {
                Text(text)
                    .font(.system(compact ? .callout : .body, design: .rounded))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
            } else {
                MarkdownText(text, font: .system(compact ? .callout : .body, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                if !message.isPending, let onSaveNote, text.count > 120 {
                    Button {
                        onSaveNote(text)
                    } label: {
                        Label(L("노트로 저장", "Save as note"), systemImage: "doc.badge.plus")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ArcaFace.ember.opacity(0.9))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isUser ? AnyShapeStyle(ArcaTheme.idle.opacity(0.88)) : AnyShapeStyle(.white.opacity(0.08)),
                    in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func imageView(_ data: Data) -> some View {
        #if os(macOS)
        if let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFit()
                .frame(maxWidth: 260, maxHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        #else
        if let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFit()
                .frame(maxWidth: 260, maxHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        #endif
    }
}

/// ARCA's thinking, drawn as a thought cloud. Streams while live (last few
/// lines visible, gently pulsing), then folds into a one-line summary you
/// can expand.
private struct ThoughtCloud: View {
    let text: String
    let live: Bool
    @Binding var expanded: Bool
    @State private var pulse = false

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var tail: String {
        let lines = trimmed.split(separator: "\n").map(String.init)
        return lines.suffix(4).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.spring(duration: 0.3)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "cloud.fill")
                        .foregroundStyle(ArcaFace.zoneViolet.opacity(pulse ? 1 : 0.6))
                    Text(live ? L("생각하는 중…", "Thinking…") : L("생각 과정 \(expanded ? "접기" : "보기")", expanded ? "Hide thinking" : "Show thinking"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    if !live {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
            .buttonStyle(.plain)

            if live || expanded {
                Text(live && !expanded ? tail : trimmed)
                    .font(.system(.caption, design: .rounded))
                    .italic()
                    .foregroundStyle(.white.opacity(live ? 0.62 : 0.72))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 18).fill(ArcaFace.zoneViolet.opacity(0.10))
                RoundedRectangle(cornerRadius: 18).strokeBorder(ArcaFace.zoneViolet.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                Circle().fill(ArcaFace.zoneViolet.opacity(0.18)).frame(width: 10, height: 10).offset(x: -4, y: 8)
                Circle().fill(ArcaFace.zoneViolet.opacity(0.14)).frame(width: 6, height: 6).offset(x: -10, y: 14)
            }
        )
        .onAppear {
            if live { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true } }
        }
        .onChange(of: live) { _, isLive in
            if !isLive { withAnimation(.easeOut(duration: 0.3)) { pulse = false } }
        }
    }
}

/// One tool step: what ARCA did, and whether it landed.
private struct ToolStepPill: View {
    let part: ChatMessage.Part

    private var symbol: String {
        switch part.toolName {
        case "search_memory": return "brain.head.profile"
        case "list_meetings", "read_meeting": return "waveform"
        case "create_todo": return "checklist"
        case "save_note": return "doc.badge.plus"
        case "open_url": return "safari"
        case "run_browser_task": return "globe"
        case "web_search": return "magnifyingglass"
        default: return "wrench"
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Group {
                switch part.toolStatus {
                case .running: ProgressView().controlSize(.mini)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
                case .none: Image(systemName: symbol)
                }
            }
            .frame(width: 14)
            Image(systemName: symbol).foregroundStyle(.white.opacity(0.6))
            Text(part.text ?? part.toolName ?? "")
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.white.opacity(0.06), in: Capsule())
    }
}
