#if os(macOS)
import Foundation

/// Best-effort Do Not Disturb toggle for ZONE mode. macOS has no public API to
/// set Focus directly, so ARCA drives it through user Shortcuts named
/// "ARCA DND On" / "ARCA DND Off" if they exist. Absent those, ZONE still
/// suppresses ARCA's own interruptions and queues sources — it just can't flip
/// the system Focus for you.
enum FocusMode {
    static func setDoNotDisturb(_ on: Bool) {
        let shortcut = on ? "ARCA DND On" : "ARCA DND Off"
        runShortcut(shortcut)
    }

    private static func runShortcut(_ name: String) {
        Thread.detachNewThread {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", name]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }
}
#endif
