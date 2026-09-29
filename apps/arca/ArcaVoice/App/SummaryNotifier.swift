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
            // First line is the gist — a notification is read once, at a glance.
            let gist = notes.summaryMarkdown
                .split(whereSeparator: \.isNewline).first
                .map { String($0.prefix(90)) } ?? title
            content.title = title
            content.body = actionCount > 0
                ? gist + L("\n할 일 \(actionCount)개 — 대신 처리할 수 있는 건 물어볼게요.", "\n\(actionCount) to-dos — I'll ask about the ones I can handle.")
                : gist
            content.sound = .default
            content.userInfo = ["sessionUID": uid]
            let request = UNNotificationRequest(
                identifier: "summary-\(uid)", content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// A meeting's deadline, ahead of time: 9 a.m. the day before and the day
    /// of. The best thing ARCA can do is keep the user from missing it.
    /// ponytail: not cancelled when the task is finished early; add removal
    /// by `deadline-<uid>` ids if that turns into noise.
    static func scheduleDeadline(for task: TodoTask) {
        guard let due = task.dueAt else { return }
        let title = task.title
        let uid = task.uid.uuidString
        Task { @MainActor in
            guard await ensurePermission() else { return }
            let calendar = Calendar.current
            let dueDay = calendar.startOfDay(for: due)
            for (offset, label) in [(-1, L("내일 마감", "Due tomorrow")), (0, L("오늘 마감", "Due today"))] {
                guard let day = calendar.date(byAdding: .day, value: offset, to: dueDay),
                      let fire = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day),
                      fire > .now else { continue }
                let content = UNMutableNotificationContent()
                content.title = label
                content.body = title
                content.sound = .default
                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire),
                    repeats: false)
                try? await UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: "deadline-\(uid)-\(offset)", content: content, trigger: trigger))
            }
        }
    }

    /// "처리했어요" — a delegated task finished while the user was elsewhere.
    static func taskHandled(title: String, needsReview: Bool) {
        Task { @MainActor in
            guard await ensurePermission() else { return }
            let content = UNMutableNotificationContent()
            content.title = needsReview ? L("초안을 준비했어요", "Your draft is ready") : L("처리했어요", "Done")
            content.body = title
            content.sound = .default
            let request = UNNotificationRequest(identifier: "task-\(UUID().uuidString)", content: content, trigger: nil)
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
