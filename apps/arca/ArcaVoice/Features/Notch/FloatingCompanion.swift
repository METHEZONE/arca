#if os(macOS)
import AppKit
import SwiftUI
import ArcaVoiceKit

/// ARCA off the notch: a small always-on-top orb you can drag anywhere, with
/// a pill of two actions on hover (record, chat). Clicking the face opens the
/// chat in its own window, so talking to ARCA never means going back to the
/// big home. Position is remembered.
@MainActor
final class FloatingCompanionController {
    static let enabledKey = "floatingCompanion"
    private static let frameKey = "floatingCompanionFrame"

    private let panel: NSPanel
    private let size = NSSize(width: 176, height: 92)

    init(services: AppServices) {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true

        let hosting = NSHostingView(rootView: FloatingOrbView(services: services))
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting

        if let saved = UserDefaults.standard.string(forKey: Self.frameKey) {
            panel.setFrameOrigin(NSPointFromString(saved))
        } else if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 24, y: frame.maxY - size.height - 80))
        }
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak panel] _ in
            guard let panel else { return }
            UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.frameKey)
        }
    }

    func close() { panel.orderOut(nil) }
}

private struct FloatingOrbView: View {
    @Bindable var services: AppServices
    @State private var hovering = false

    private var isRecording: Bool { services.coordinator.phase != .idle }

    var body: some View {
        HStack(spacing: 10) {
            if hovering {
                HStack(spacing: 6) {
                    Button {
                        if isRecording { services.stopRecording() } else { services.startRecording() }
                    } label: {
                        Image(systemName: isRecording ? "stop.fill" : "waveform")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 30, height: 30)
                            .foregroundStyle(isRecording ? ArcaTheme.recording : .white)
                    }
                    .buttonStyle(.plain)
                    .help(isRecording ? L("녹음 정지", "Stop recording") : L("녹음 시작", "Start recording"))
                    Button {
                        NotificationCenter.default.post(name: .arcaOpenChatWindow, object: nil)
                    } label: {
                        Image(systemName: "keyboard")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 30, height: 30)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .help(L("채팅 열기", "Open chat"))
                }
                .padding(.horizontal, 6)
                .background(Color(red: 0.10, green: 0.11, blue: 0.16).opacity(0.95), in: Capsule())
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            Button {
                NotificationCenter.default.post(name: .arcaOpenChatWindow, object: nil)
            } label: {
                ArcaFace(mood: isRecording ? .listening : .idle, size: 58, halo: true, followsPointer: true)
                    .frame(width: 72, height: 72)
                    .shadow(color: ArcaSkins.current.mid.opacity(0.5), radius: 14)
            }
            .buttonStyle(.plain)
            .help(L("ARCA와 대화 · 드래그해서 옮기기", "Talk to ARCA · drag to move"))
            .contextMenu {
                Button(L("채팅 열기", "Open chat")) { NotificationCenter.default.post(name: .arcaOpenChatWindow, object: nil) }
                Button(isRecording ? L("녹음 정지", "Stop recording") : L("녹음 시작", "Start recording")) {
                    if isRecording { services.stopRecording() } else { services.startRecording() }
                }
                Divider()
                Button(L("숨기기 (설정에서 다시 켤 수 있어요)", "Hide (turn back on in Settings)")) {
                    services.setFloatingCompanion(enabled: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 4)
        .onHover { inside in withAnimation(.spring(duration: 0.28)) { hovering = inside } }
        .animation(.spring(duration: 0.28), value: hovering)
    }
}

extension Notification.Name {
    static let arcaOpenChatWindow = Notification.Name("arca.openChatWindow")
}
#endif
