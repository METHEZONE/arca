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
            AppServices.shared.notch.celebrate(L("회의록 준비됨 — \(title)", "Notes ready — \(title)"))
            #endif
            guard await ensurePermission() else { return }
            let content = UNMutableNotificationContent()
            content.title = L("✅ 회의록이 준비됐어요", "✅ Notes ready")
            content.body = actionCount > 0
                ? L("\(title) — 요약 + 액션 \(actionCount)개", "\(title) — summary + \(actionCount) action\(actionCount == 1 ? "" : "s")")
                : L("\(title) — 요약이 라이브러리에 있어요", "\(title) — summary is in your library")
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
            content.title = L("⚠️ 녹음은 저장됐지만 처리에 실패했어요", "⚠️ Recording saved, processing failed")
            content.body = "\(title) — \(message)"
            content.sound = .default
            content.userInfo = ["sessionUID": uid]
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "summary-fail-\(uid)", content: content, trigger: nil))
        }
    }
}
