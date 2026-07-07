#if os(iOS)
import AppIntents
import Foundation

extension Notification.Name {
    /// Posted by island buttons; the app toggles recording in response.
    public static let arcaToggleRecording = Notification.Name("arca.toggleRecording")
}

/// Tap target for the Dynamic Island buttons. LiveActivityIntents run inside
/// the app's process, so a NotificationCenter post is enough to reach
/// AppServices — and the type also compiles in the widget extension without
/// dragging app code along.
struct ArcaToggleRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Toggle ARCA recording"
    static let description = IntentDescription("Start or stop an ARCA recording.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .arcaToggleRecording, object: nil)
        }
        return .result()
    }
}
#endif
