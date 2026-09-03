#if os(macOS)
import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import Observation
import SwiftUI
import ArcaVoiceKit

/// Microphone access, read without prompting.
///
/// Separate from the drag flow because the Microphone pane is a plain switch
/// list — there's nothing to drop into it, and unlike the TCC app lists macOS
/// will show its own prompt the first time recording starts.
enum MicrophonePermission {
    static var isGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var wasDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
    }
}

/// The macOS permissions ARCA needs, and what breaks without each one.
///
/// Stated in terms of the feature the user loses rather than the API, because
/// "화면 기록" on its own doesn't tell anyone why a note-taking app wants it.
enum MacPermission: String, CaseIterable, Identifiable, Sendable {
    case screenRecording
    case accessibility
    case microphone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording: return L("화면 기록", "Screen Recording")
        case .accessibility: return L("손쉬운 사용", "Accessibility")
        case .microphone: return L("마이크", "Microphone")
        }
    }

    var why: String {
        switch self {
        case .screenRecording:
            return L("하루 스냅샷, 노치에 떨어뜨린 화면 읽기, 회의 참석자 이름 인식에 필요해요.",
                     "Needed for day snapshots, reading a screen you drop on the notch, and picking up participant names in a call.")
        case .accessibility:
            return L("전역 단축키(오른쪽 ⌘ 두 번)로 화면을 잡아 바로 대화하려면 필요해요.",
                     "Needed for the global hotkey (double-tap right ⌘) that grabs the screen and starts a chat.")
        case .microphone:
            return L("회의와 음성 메모를 녹음하려면 필요해요.",
                     "Needed to record meetings and voice notes.")
        }
    }

    /// The exact System Settings pane, so nobody has to go hunting.
    var settingsURL: URL? {
        switch self {
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    }

    /// Whether the pane is an add-an-app list you can drop a bundle into.
    ///
    /// Screen Recording and Accessibility are: they have a `+` that opens a file
    /// picker, which is where people get lost. Microphone is a plain switch list —
    /// there is nothing to drag, so offering a drag would be a lie.
    var acceptsAppDrop: Bool {
        switch self {
        case .screenRecording, .accessibility: return true
        case .microphone: return false
        }
    }

    var isGranted: Bool {
        switch self {
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        case .accessibility: return AXIsProcessTrusted()
        case .microphone: return MicrophonePermission.isGranted
        }
    }

    /// TCC changes for these two usually only take hold on the next launch.
    var needsRelaunchAfterGrant: Bool { acceptsAppDrop }
}

/// Walks the user through a macOS permission by opening the right pane and
/// floating a panel with ARCA's icon in it to drag into the list.
///
/// The drag exists because the `+` button opens a file picker at some arbitrary
/// folder and the user has to know that apps live in `/Applications` — which is
/// the step everyone fails. Dropping the icon skips the whole navigation.
@MainActor
@Observable
final class MacPermissionCoach {
    static let shared = MacPermissionCoach()

    private(set) var active: MacPermission?
    private(set) var grantedJustNow: MacPermission?

    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    /// Opens the pane and floats the drag panel above it.
    func begin(_ permission: MacPermission) {
        guard !permission.isGranted else {
            grantedJustNow = permission
            return
        }
        active = permission
        grantedJustNow = nil

        if let url = permission.settingsURL {
            NSWorkspace.shared.open(url)
        }
        // Microphone is a plain switch list — nothing to drop, so no drag card;
        // the pane is open and we just wait for the switch to flip.
        guard permission.acceptsAppDrop else {
            startPolling(permission)
            return
        }
        // A beat, so the panel lands on top of System Settings rather than being
        // buried by it as it comes forward.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard active == permission else { return }
            presentPanel(for: permission)
            startPolling(permission)
        }
    }

    func dismiss() {
        pollTask?.cancel()
        pollTask = nil
        panel?.orderOut(nil)
        panel = nil
        active = nil
    }

    /// Relaunches ARCA so a fresh TCC grant actually takes effect.
    func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    private func startPolling(_ permission: MacPermission) {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            // Ten minutes is longer than anyone needs, and the panel's close
            // button is always there — this only stops a forgotten poll loop.
            for _ in 0..<600 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                guard permission.isGranted else { continue }
                self?.grantedJustNow = permission
                self?.dismiss()
                return
            }
        }
    }

    private func presentPanel(for permission: MacPermission) {
        panel?.orderOut(nil)

        let content = PermissionDragPanelView(permission: permission)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: 460, height: 190)

        // Non-activating: the user has to drag OUT of this panel and INTO the
        // System Settings window, so ARCA must never steal focus and push
        // Settings behind it.
        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Dragging the icon must drag the icon, not the card. A movable
        // background swallowed the drag and the whole panel followed the pointer.
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = hosting

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - hosting.frame.width / 2,
                y: frame.minY + 160))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

/// The floating card: instruction, a draggable ARCA icon, and a way out.
private struct PermissionDragPanelView: View {
    let permission: MacPermission

    @State private var coach = MacPermissionCoach.shared
    @State private var isDragging = false

    private var appIcon: NSImage { NSApp.applicationIconImage ?? NSImage() }
    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "ARCA"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    coach.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text(instruction)
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(appName)
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                    // The path matters: a Debug build dragged in from DerivedData
                    // grants permission to *that* copy, not the one in
                    // /Applications, which is exactly how a grant "stops working".
                    Text(Bundle.main.bundleURL.deletingLastPathComponent().path)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(isDragging ? 0.2 : 0.45))
                    .symbolEffect(.pulse, options: .repeating, isActive: !isDragging)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.white.opacity(isDragging ? 0.04 : 0.10),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(0.16)))
            .opacity(isDragging ? 0.5 : 1)
            // Dragging the app bundle as a file URL is what the TCC list accepts —
            // the same thing the `+` file picker would have handed it.
            .onDrag {
                isDragging = true
                return NSItemProvider(object: Bundle.main.bundleURL as NSURL)
            }
            .help(L("이 아이콘을 위 목록으로 끌어다 놓으세요",
                    "Drag this icon into the list above"))

            Text(L("끌어다 놓기가 안 되면 목록의 + 를 누르고 위 경로에서 \(appName)을 고르세요.",
                   "If dragging doesn't work, click + in the list and pick \(appName) from the path above."))
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 460, alignment: .leading)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12)))
    }

    private var instruction: String {
        L("위 목록으로 \(appName)을 끌어다 놓으면 \(permission.title) 권한이 켜져요.",
          "Drag \(appName) into the list above to allow \(permission.title).")
    }
}
#endif
