#if os(macOS)
import AppKit
import SwiftUI
import ArcaVoiceKit

/// ARCA off the notch: a small always-on-top orb you can drag anywhere, with
/// a pill of two actions on hover (record, chat). Clicking the face opens the
/// chat in its own window. During the first-run tour the same orb flies to
/// each place in the app and explains it in a speech bubble — the guide is
/// the companion, not a card.
@MainActor
final class FloatingCompanionController {
    static let enabledKey = "floatingCompanion"
    private static let frameKey = "floatingCompanionFrame"

    private let panel: NSPanel
    private let idleSize = NSSize(width: 220, height: 130)
    private let tourSize = NSSize(width: 620, height: 210)
    private var restingOrigin: NSPoint?

    init(services: AppServices) {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: idleSize),
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

        let hosting = NSHostingView(rootView: FloatingOrbView(services: services, tour: TourDirector.shared))
        hosting.frame = NSRect(origin: .zero, size: idleSize)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting

        if let saved = UserDefaults.standard.string(forKey: Self.frameKey) {
            panel.setFrameOrigin(NSPointFromString(saved))
        } else if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - idleSize.width - 16, y: frame.maxY - idleSize.height - 60))
        }
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self, weak panel] _ in
            guard let self, let panel, !TourDirector.shared.isActive else { return }
            UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.frameKey)
        }

        TourDirector.shared.onMove = { [weak self] anchor in self?.fly(to: anchor) }
        TourDirector.shared.onEnd = { [weak self] in self?.settle() }
    }

    func close() { panel.orderOut(nil) }

    /// Tour: grow to fit the bubble and glide so the orb sits just right of `anchor` (screen coords).
    private func fly(to anchor: CGRect?) {
        if restingOrigin == nil { restingOrigin = panel.frame.origin }
        panel.isMovableByWindowBackground = false
        var target = NSRect(origin: panel.frame.origin, size: tourSize)
        if let anchor {
            target.origin = NSPoint(x: anchor.maxX + 6, y: anchor.midY - tourSize.height / 2)
        } else if let screen = NSScreen.main {
            target.origin = NSPoint(x: screen.visibleFrame.midX - tourSize.width / 2, y: screen.visibleFrame.midY)
        }
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            target.origin.x = min(max(target.origin.x, v.minX + 8), v.maxX - tourSize.width - 8)
            target.origin.y = min(max(target.origin.y, v.minY + 8), v.maxY - tourSize.height - 8)
        }
        (panel.contentView as? NSHostingView<FloatingOrbView>)?.frame = NSRect(origin: .zero, size: tourSize)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.55
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        }
        panel.orderFrontRegardless()
    }

    /// Tour over: back to the small orb where it was resting.
    private func settle() {
        let origin = restingOrigin ?? panel.frame.origin
        restingOrigin = nil
        let target = NSRect(origin: origin, size: idleSize)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.45
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                (self.panel.contentView as? NSHostingView<FloatingOrbView>)?.frame = NSRect(origin: .zero, size: self.idleSize)
                self.panel.isMovableByWindowBackground = true
            }
        })
    }
}

/// Drives the first-run tour: which step is showing, where the orb should be,
/// what it says. Owned by the floating companion; fed anchors by the home.
@MainActor
@Observable
final class TourDirector {
    static let shared = TourDirector()

    struct Step {
        let section: ArcaSection?
        let title: String
        let body: String
        let cta: String?
    }

    private(set) var isActive = false
    private(set) var index = 0
    private(set) var steps: [Step] = []
    var onMove: ((CGRect?) -> Void)?
    var onEnd: (() -> Void)?
    private var anchorFor: ((ArcaSection?) -> CGRect?)?
    private var onFocus: ((ArcaSection?) -> Void)?
    private var onRecord: (() -> Void)?

    var current: Step? { isActive && index < steps.count ? steps[index] : nil }
    var isLast: Bool { index >= steps.count - 1 }

    func start(steps: [Step], anchorFor: @escaping (ArcaSection?) -> CGRect?,
               onFocus: @escaping (ArcaSection?) -> Void, onRecord: @escaping () -> Void) {
        self.steps = steps
        self.anchorFor = anchorFor
        self.onFocus = onFocus
        self.onRecord = onRecord
        index = 0
        isActive = true
        place()
    }

    func next() {
        guard index + 1 < steps.count else { finish(); return }
        index += 1
        place()
    }

    func skip() { finish() }

    func startRecordingAndFinish() {
        finish()
        onRecord?()
    }

    /// Anchors move with the window; re-place after layout settles.
    func refreshPlacement() { if isActive { place() } }

    private func place() {
        guard let step = current else { return }
        onFocus?(step.section)
        // Let the sidebar highlight/scroll land before measuring.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            onMove?(anchorFor?(step.section))
        }
    }

    private func finish() {
        AccountDefaults.set(true, for: CompanionTour.doneKey)
        isActive = false
        onFocus?(nil)
        onEnd?()
    }
}

private struct FloatingOrbView: View {
    @Bindable var services: AppServices
    @Bindable var tour: TourDirector
    @State private var hovering = false

    private var isRecording: Bool { services.coordinator.phase != .idle }

    var body: some View {
        if tour.isActive, let step = tour.current {
            HStack(alignment: .center, spacing: 6) {
                orb(size: 64)
                SpeechBubble {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(step.title)
                            .font(.system(.headline, design: .rounded, weight: .bold))
                        Text(step.body)
                            .font(.system(.callout, design: .rounded))
                            .foregroundStyle(.white.opacity(0.82))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            HStack(spacing: 4) {
                                ForEach(0..<tour.steps.count, id: \.self) { i in
                                    Capsule().fill(i <= tour.index ? ArcaSkins.current.mid : .white.opacity(0.15))
                                        .frame(width: i == tour.index ? 16 : 6, height: 5)
                                }
                            }
                            Spacer()
                            Button(L("건너뛰기", "Skip")) { tour.skip() }
                                .buttonStyle(.plain)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.5))
                            if let cta = step.cta {
                                Button { tour.startRecordingAndFinish() } label: {
                                    Label(cta, systemImage: "waveform")
                                        .font(.system(.callout, design: .rounded, weight: .bold))
                                        .padding(.horizontal, 14).padding(.vertical, 7)
                                        .background(ArcaSkins.current.mid, in: Capsule())
                                        .foregroundStyle(.black)
                                }
                                .buttonStyle(.arcaPress)
                            } else {
                                Button { tour.next() } label: {
                                    Text(tour.isLast ? L("끝", "Done") : L("다음", "Next"))
                                        .font(.system(.callout, design: .rounded, weight: .bold))
                                        .padding(.horizontal, 16).padding(.vertical, 7)
                                        .background(ArcaSkins.current.mid, in: Capsule())
                                        .foregroundStyle(.black)
                                }
                                .buttonStyle(.arcaPress)
                            }
                        }
                    }
                }
                .frame(width: 500)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
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
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                orb(size: 58)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .padding(.trailing, 22)
            .onHover { inside in withAnimation(.spring(duration: 0.28)) { hovering = inside } }
            .animation(.spring(duration: 0.28), value: hovering)
        }
    }

    /// The orb, with generous transparent room around it so its halo never
    /// meets the panel edge (a clipped glow reads as a dark square).
    private func orb(size: CGFloat) -> some View {
        Button {
            NotificationCenter.default.post(name: .arcaOpenChatWindow, object: nil)
        } label: {
            ArcaFace(mood: isRecording ? .listening : (tour.isActive ? .happy : .idle), size: size, halo: true, followsPointer: true)
                .frame(width: size * 1.6, height: size * 1.6)
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
}

/// A speech bubble whose tail points left, at the orb.
private struct SpeechBubble<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(16)
            .background(
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(red: 0.08, green: 0.09, blue: 0.15).opacity(0.97))
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(ArcaSkins.current.mid.opacity(0.45))
                    BubbleTail()
                        .fill(Color(red: 0.08, green: 0.09, blue: 0.15).opacity(0.97))
                        .frame(width: 12, height: 20)
                        .offset(x: -11)
                }
            )
            .shadow(color: .black.opacity(0.45), radius: 20, y: 8)
    }
}

private struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

extension Notification.Name {
    static let arcaOpenChatWindow = Notification.Name("arca.openChatWindow")
}
#endif
