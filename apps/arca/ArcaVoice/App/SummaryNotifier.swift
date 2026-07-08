import Foundation
import UserNotifications
import ArcaVoiceKit

/// Closes the capture loop for the user: when a recording finishes its
/// quality pass, say so — a system notification (banner, top-right on macOS,
/// lock screen / island on iOS) plus the Mac notch celebration.
@MainActor
enum SummaryNotifier {
    /// Ask once, lazily, right before the first notification would show.
    private static func ensurePermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default:
            return false
        }
    }

    static func summaryReady(record: RecordingSession, notes: MeetingNotes) {
        let title = record.title
        let actionCount = notes.actionItems.count
        let uid = record.directoryName

        Task { @MainActor in
            #if os(macOS)
            AppServices.shared.notch.celebrate("Notes ready — \(title)")
            #endif
            guard await ensurePermission() else { return }
            let content = UNMutableNotificationContent()
            content.title = "✅ Notes ready"
            content.body = actionCount > 0
                ? "\(title) — summary + \(actionCount) action\(actionCount == 1 ? "" : "s")"
                : "\(title) — summary is in your library"
            content.sound = .default
            content.userInfo = ["sessionUID": uid]
            let request = UNNotificationRequest(
                identifier: "summary-\(uid)", content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    static func processingFailed(record: RecordingSession, message: String) {
        let title = record.title
        let uid = record.directoryName
        Task { @MainActor in
            guard await ensurePermission() else { return }
            let content = UNMutableNotificationContent()
            content.title = "⚠️ Recording saved, processing failed"
            content.body = "\(title) — \(message)"
            content.sound = .default
            content.userInfo = ["sessionUID": uid]
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "summary-fail-\(uid)", content: content, trigger: nil))
        }
    }
}
