#if os(macOS)
import SwiftUI
import SwiftData
import ArcaVoiceKit

/// The hover dashboard that drops out of the notch: our chat history on the
/// left (with a way to keep talking), your live to-do tracker on the right
/// (quick-add + ARCA's "Toss" for anything it can run itself), and Record /
/// ZONE / app shortcuts up top. The main window stays the library; this is
/// the ambient, always-one-hover-away surface.
struct DashboardView: View {
    let agent: NotchAgent
    @State private var zone = AppServices.shared.zone

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(.white.opacity(0.08))
            HStack(spacing: 0) {
                ChatLogColumn(agent: agent)
                    .frame(maxWidth: .infinity)
                Divider().overlay(.white.opacity(0.08))
                TodoColumn()
                    .frame(width: 340)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            miniEyes
            Text("ARCA")
                .font(.system(.subheadline, design: .rounded, weight: .bold))
            Spacer()
            recordButton
            ZoneToggle(zone: zone)
            Button {
                agent.openApp()
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Open the ARCA app")
        }
        .padding(.vertical, 10)
    }

    private var recordButton: some View {
        Button {
            AppServices.shared.startRecording()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                Text("Record")
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(ArcaTheme.recording.opacity(0.9), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Start recording — live transcript, speakers separated")
    }

    private var miniEyes: some View {
        ArcaFace(mood: .idle, size: 22, halo: false)
            .frame(width: 24, height: 24)
    }
}

// MARK: - Chat column

private struct ChatLogColumn: View {
    let agent: NotchAgent
    @Environment(\.modelContext) private var context
    @Query(sort: \ChatLogEntry.createdAt, order: .forward) private var log: [ChatLogEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BriefingCard(compact: true)
                .padding(.top, 6)
            HStack {
                Label("Chat", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button {
                    agent.startBlankChat()
                } label: {
                    Label("New chat", systemImage: "plus.bubble")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(ArcaTheme.idle)
            }
            .padding(.top, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(log.suffix(40)) { entry in
                            LogRow(entry: entry).id(entry.persistentModelID)
                        }
                    }
                    .padding(.trailing, 8)
                }
                .onAppear {
                    if let last = log.last { proxy.scrollTo(last.persistentModelID, anchor: .bottom) }
                }
            }
            .overlay {
                if log.isEmpty {
                    Text("No conversations yet.\nDrag a screenshot onto the notch,\nor start a new chat.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .padding(.trailing, 12)
    }
}

private struct LogRow: View {
    let entry: ChatLogEntry
    private var isUser: Bool { entry.roleRaw == "user" }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isUser { Spacer(minLength: 30) }
            Text(entry.text)
                .font(.caption)
                .foregroundStyle(isUser ? .white : .white.opacity(0.85))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(
                    isUser ? AnyShapeStyle(ArcaTheme.idle.opacity(0.85)) : AnyShapeStyle(.white.opacity(0.08)),
                    in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: 300, alignment: isUser ? .trailing : .leading)
            if !isUser { Spacer(minLength: 30) }
        }
    }
}

// MARK: - Zone toggle

private struct ZoneToggle: View {
    @Bindable var zone: ZoneEngine

    var body: some View {
        Button {
            if zone.isActive { zone.stop() } else { zone.start() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: zone.isActive ? "moon.stars.fill" : "moon.stars")
                Text(zone.isActive ? "End ZONE" : "ZONE")
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(zone.isActive ? AnyShapeStyle(ArcaTheme.idle) : AnyShapeStyle(.white.opacity(0.12)),
                        in: Capsule())
        }
        .buttonStyle(.plain)
        .help(zone.isActive ? "End focus mode and get the report" : "Start focus mode — ARCA guards interruptions")
    }
}
#endif
