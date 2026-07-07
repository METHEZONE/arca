#if os(macOS)
import AppKit

/// Which modifier double-tap triggers ARCA's instant screen chat.
/// Kept to modifier double-taps so no full key-recorder is needed.
enum ChatHotkey: String, CaseIterable, Identifiable {
    case rightCommand, leftCommand, rightOption, leftOption, rightControl

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rightCommand: return "Right ⌘ double-tap"
        case .leftCommand: return "Left ⌘ double-tap"
        case .rightOption: return "Right ⌥ double-tap"
        case .leftOption: return "Left ⌥ double-tap"
        case .rightControl: return "Right ⌃ double-tap"
        }
    }

    /// The hardware keyCode reported in flagsChanged for this modifier.
    var keyCode: UInt16 {
        switch self {
        case .rightCommand: return 54
        case .leftCommand: return 55
        case .rightOption: return 61
        case .leftOption: return 58
        case .rightControl: return 62
        }
    }

    /// The modifier flag that must be present on the press edge.
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .rightCommand, .leftCommand: return .command
        case .rightOption, .leftOption: return .option
        case .rightControl: return .control
        }
    }
}

/// Watches for a configured modifier double-tap and fires a callback.
/// Requires Accessibility permission for the global monitor to see events.
@MainActor
final class HotkeyMonitor {
    var onTrigger: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastPressAt: TimeInterval = 0
    private var wasDown = false

    var hotkey: ChatHotkey {
        ChatHotkey(rawValue: UserDefaults.standard.string(forKey: "chatHotkey") ?? "")
            ?? .rightCommand
    }
    var doubleTapWindow: Double {
        let stored = UserDefaults.standard.double(forKey: "chatHotkeyWindow")
        return stored > 0 ? stored : 0.4
    }

    func start() {
        stop()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handle(_ event: NSEvent) {
        let key = hotkey
        guard event.keyCode == key.keyCode else { return }
        // flagsChanged fires on both press and release; the press edge is when
        // the modifier flag is now present.
        let isDown = event.modifierFlags.contains(key.flag)
        defer { wasDown = isDown }
        guard isDown, !wasDown else { return }

        let now = event.timestamp
        if now - lastPressAt <= doubleTapWindow {
            lastPressAt = 0
            onTrigger?()
        } else {
            lastPressAt = now
        }
    }
}
#endif
