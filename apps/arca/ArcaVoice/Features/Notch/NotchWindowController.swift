#if os(macOS)
import AppKit
import SwiftData
import SwiftUI

/// Hosts ARCA's notch presence: a borderless, always-on-top, transparent panel
/// hugging the top of the notched display. AppKit performs pixel-alpha
/// click-through on borderless transparent windows, so only the visible black
/// shape receives clicks; the rest of the panel passes them through.
///
/// The window itself NEVER resizes — it is created at the largest surface size
/// and only the SwiftUI shape inside animates. Window-frame animation both
/// fought the SwiftUI spring (jank) and previously crashed AppKit's Auto
/// Layout. Hover/drag activation is gated by mode-dependent hot zones so the
/// oversized invisible window doesn't act like an oversized hover target.
@MainActor
final class NotchWindowController {
    private let panel: NSPanel
    private let screen: NSScreen
    private let panelSize: NSSize
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    /// Geometry of the physical notch (or a synthetic pill on external displays).
    struct NotchGeometry {
        let notchWidth: CGFloat
        let notchHeight: CGFloat
        let hasNotch: Bool
    }

    init(agent: NotchAgent, coordinator: RecordingCoordinator, container: ModelContainer) {
        let screen = Self.preferredScreen()
        let geometry = Self.geometry(for: screen)
        self.screen = screen

        // Fixed window big enough for every surface (dashboard is the widest,
        // chat the tallest). Transparent overflow passes clicks through.
        self.panelSize = NSSize(width: max(geometry.notchWidth + 800, 960), height: 680)

        // Borderless but NOT non-activating: clicking the notch to chat is a
        // user-initiated interaction, so it may activate ARCA and give the chat
        // text field keyboard focus. (macOS 14+ blocks background apps from
        // force-activating themselves, so the activation must ride a user event.)
        panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true

        // The dashboard's @Query views need the SwiftData container in this
        // hosting tree's environment — the notch panel is outside the SwiftUI
        // scene, so nothing injects it for us.
        let root = NotchView(agent: agent, coordinator: coordinator, geometry: geometry)
            .modelContainer(container)
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.frame = NSRect(origin: .zero, size: panelSize)
        hosting.autoresizingMask = [.width, .height]

        let dropView = NotchDropView(frame: NSRect(origin: .zero, size: panelSize))
        dropView.agent = agent
        dropView.geometry = geometry
        dropView.translatesAutoresizingMaskIntoConstraints = true
        dropView.addSubview(hosting)
        panel.contentView = dropView

        place()
        panel.orderFrontRegardless()

        // The idle eyes follow the cursor anywhere on screen. Mouse-move
        // monitors need no special permission (unlike keyboard taps).
        let notchCenter = CGPoint(x: screen.frame.midX, y: screen.frame.maxY)
        let updateLook: (NSPoint) -> Void = { [weak agent] location in
            guard let agent else { return }
            let dx = max(-1, min(1, (location.x - notchCenter.x) / (screen.frame.width / 2)))
            let dy = max(-1, min(1, (notchCenter.y - location.y) / 600))
            // Deadzone: tiny cursor jitters shouldn't twitch the eyes.
            let current = agent.pointerLook
            guard abs(dx - current.x) > 0.06 || abs(dy - current.y) > 0.06 else { return }
            agent.pointerLook = CGPoint(x: dx, y: dy)
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { event in
            MainActor.assumeIsolated { updateLook(NSEvent.mouseLocation) }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { event in
            MainActor.assumeIsolated { updateLook(NSEvent.mouseLocation) }
            return event
        }

        // Only chat needs window-level attention: activate so the text field
        // receives keys, and hide standard app windows so the notch is the
        // focus. Everything else is pure SwiftUI animation inside the panel.
        agent.onModeChange = { [weak self] mode in
            guard let self else { return }
            if mode == .chat {
                for window in NSApp.windows where window !== self.panel
                    && window.styleMask.contains(.titled) && window.isVisible {
                    window.orderOut(nil)
                }
                NSApp.activate(ignoringOtherApps: true)
                self.panel.makeKeyAndOrderFront(nil)
            } else if self.panel.isKeyWindow {
                self.panel.resignKey()
            }
        }
    }

    /// Pin the window's top edge to the screen top and center it horizontally.
    private func place() {
        let screenFrame = screen.frame
        let origin = NSPoint(x: screenFrame.midX - panelSize.width / 2,
                             y: screenFrame.maxY - panelSize.height)
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true, animate: false)
    }

    /// Buttons in a non-activating panel must react to the FIRST click —
    /// without this, the initial click is consumed by window ordering.
    private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// The notch container: hover activation, image drag-and-drop, and the
    /// mode-dependent hot zones that keep the oversized window honest.
    private final class NotchDropView: NSView {
        weak var agent: NotchAgent?
        var geometry: NotchGeometry?
        private var tracking: NSTrackingArea?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([.fileURL, .png, .tiff])
        }
        required init?(coder: NSCoder) { fatalError() }

        // MARK: Hot zones (view coords, origin bottom-left, top edge = maxY)

        /// A rect of `width`×`height` hugging the top-center of the view.
        private func topZone(width: CGFloat, height: CGFloat) -> CGRect {
            CGRect(x: bounds.midX - width / 2, y: bounds.maxY - height,
                   width: width, height: height)
        }

        /// Where hovering may OPEN the dashboard: the physical notch plus the
        /// menu-bar flanks where the face and status pills live.
        private var notchZone: CGRect {
            guard let g = geometry else { return .zero }
            return g.hasNotch
                ? topZone(width: g.notchWidth + 96, height: g.notchHeight + 2)
                : topZone(width: 190, height: 40)
        }

        /// Where the dashboard stays open while the pointer roams it.
        private var dashboardZone: CGRect {
            guard let g = geometry else { return .zero }
            return topZone(width: g.notchWidth + 780, height: 545 + g.notchHeight)
        }

        /// Where a dragged image engages/lands once the mouth is open.
        private var dropZone: CGRect {
            guard let g = geometry else { return .zero }
            return topZone(width: g.notchWidth + 260, height: g.notchHeight + 190)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        private func handleHover(at point: CGPoint) {
            MainActor.assumeIsolated {
                guard let agent else { return }
                switch agent.mode {
                case .idle, .menu:
                    if notchZone.contains(point) { agent.hoverOpen() }
                case .dashboard:
                    if dashboardZone.contains(point) {
                        agent.hoverStay()
                    } else {
                        agent.hoverClose()
                    }
                default:
                    break
                }
            }
        }

        override func mouseEntered(with event: NSEvent) {
            handleHover(at: convert(event.locationInWindow, from: nil))
        }
        override func mouseMoved(with event: NSEvent) {
            handleHover(at: convert(event.locationInWindow, from: nil))
        }
        override func mouseExited(with event: NSEvent) {
            MainActor.assumeIsolated { agent?.hoverClose() }
        }

        // MARK: Drag & drop

        private func hasImage(_ sender: NSDraggingInfo) -> Bool {
            let pb = sender.draggingPasteboard
            if pb.canReadObject(forClasses: [NSImage.self], options: nil) { return true }
            if let urls = pb.readObjects(forClasses: [NSURL.self],
                                         options: [.urlReadingContentsConformToTypes: ["public.image"]]) as? [URL],
               !urls.isEmpty { return true }
            return false
        }

        /// Dragging engages near the notch only (or anywhere in the open mouth).
        private func dragOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard hasImage(sender) else { return [] }
            let point = convert(sender.draggingLocation, from: nil)
            let engaged = MainActor.assumeIsolated { agent?.mode == .dropTarget }
            let zone = engaged
                ? dropZone
                : notchZone.insetBy(dx: -50, dy: 0).union(
                    topZone(width: (geometry?.notchWidth ?? 180) + 100,
                            height: (geometry?.notchHeight ?? 32) + 44))
            if zone.contains(point) {
                MainActor.assumeIsolated { agent?.setDropTargeting(true) }
                return .copy
            }
            MainActor.assumeIsolated { agent?.setDropTargeting(false) }
            return []
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            dragOperation(sender)
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            dragOperation(sender)
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            MainActor.assumeIsolated { agent?.setDropTargeting(false) }
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let point = convert(sender.draggingLocation, from: nil)
            guard dropZone.contains(point) else {
                MainActor.assumeIsolated { agent?.setDropTargeting(false) }
                return false
            }
            let pb = sender.draggingPasteboard
            var image: NSImage?
            if let urls = pb.readObjects(forClasses: [NSURL.self],
                                         options: [.urlReadingContentsConformToTypes: ["public.image"]]) as? [URL],
               let url = urls.first {
                image = NSImage(contentsOf: url)
            }
            if image == nil {
                image = NSImage(pasteboard: pb)
            }
            guard let image, let jpeg = Self.jpeg(from: image) else {
                MainActor.assumeIsolated { agent?.setDropTargeting(false) }
                return false
            }
            MainActor.assumeIsolated { agent?.startChat(withImage: jpeg) }
            return true
        }

        private static func jpeg(from image: NSImage, maxDimension: CGFloat = 1600) -> Data? {
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else { return nil }
            // Downscale if large.
            let w = CGFloat(rep.pixelsWide), h = CGFloat(rep.pixelsHigh)
            let scale = min(1, maxDimension / max(w, h))
            if scale < 1 {
                let target = NSSize(width: w * scale, height: h * scale)
                let resized = NSImage(size: target)
                resized.lockFocus()
                image.draw(in: NSRect(origin: .zero, size: target))
                resized.unlockFocus()
                if let t = resized.tiffRepresentation, let r = NSBitmapImageRep(data: t) {
                    return r.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
                }
            }
            return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        }
    }

    /// A borderless panel that can still become key — required so the chat
    /// text field accepts typing while the panel stays non-activating otherwise.
    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    static func preferredScreen() -> NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    static func geometry(for screen: NSScreen) -> NotchGeometry {
        let inset = screen.safeAreaInsets.top
        if inset > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return NotchGeometry(notchWidth: width, notchHeight: inset, hasNotch: true)
        }
        // External display: float a synthetic pill just below the menu bar.
        return NotchGeometry(notchWidth: 180, notchHeight: 0, hasNotch: false)
    }
}
#endif
