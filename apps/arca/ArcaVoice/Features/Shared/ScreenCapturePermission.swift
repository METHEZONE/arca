#if os(macOS)
import CoreGraphics

/// One gate for every screen-capture attempt. Attempting a capture without
/// permission is what makes macOS throw its modal — and periodic callers
/// (day-tracker snapshots) were re-triggering it every few minutes after a
/// signing change invalidated the old grant. Preflight never prompts; the
/// system dialog is allowed AT MOST once per launch.
@MainActor
enum ScreenCapturePermission {
    private static var requestedThisLaunch = false

    /// True when the app may capture right now. Never shows a dialog.
    static var granted: Bool { CGPreflightScreenCaptureAccess() }

    /// Returns whether capture is allowed, showing the system prompt at most
    /// once per launch when it isn't.
    @discardableResult
    static func requestOnce() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        guard !requestedThisLaunch else { return false }
        requestedThisLaunch = true
        return CGRequestScreenCaptureAccess()
    }
}
#endif
