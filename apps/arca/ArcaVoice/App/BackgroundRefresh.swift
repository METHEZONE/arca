#if os(iOS)
import BackgroundTasks
import UIKit

/// Devices used to converge only when the app was opened — the Mac polls
/// every 60s, but the phone went stale in your pocket. This keeps the phone
/// side of the relay warm: a BGAppRefresh task syncs in the background, and
/// a flush on backgrounding pushes anything you just did before iOS
/// suspends us.
enum BackgroundRefresh {
    static let taskID = "com.thezone.arca.voice.relaysync"

    /// Must be called before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            handle(task)
        }
    }

    /// Ask iOS for a wake sometime after 15 minutes; the system decides when.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Push pending local changes while iOS still gives us runtime.
    static func flushOnBackground() {
        let flushID = UIApplication.shared.beginBackgroundTask(withName: "arca.relay.flush")
        Task { @MainActor in
            await RelaySync.shared.syncNow()
            UIApplication.shared.endBackgroundTask(flushID)
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule() // keep the chain alive for the next wake
        nonisolated(unsafe) let task = task
        let work = Task { @MainActor in
            await RelaySync.shared.syncNow()
            task.setTaskCompleted(success: RelaySync.shared.lastError == nil)
        }
        task.expirationHandler = { work.cancel() }
    }
}
#endif
