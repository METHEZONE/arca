import Foundation
import WatchConnectivity

/// Ships finished recordings to the paired iPhone. WCSession file transfers
/// queue and survive the app closing — fire and forget.
final class WatchSync: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchSync()

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func send(file: URL, duration: TimeInterval, createdAt: Date) {
        WCSession.default.transferFile(file, metadata: [
            "duration": duration,
            "createdAt": createdAt.timeIntervalSince1970,
        ])
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}

    /// Summaries coming back from the iPhone once processing finishes.
    /// Fields are extracted here so only Sendable values cross to the main actor.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard (userInfo["type"] as? String) == "summary",
              let uid = userInfo["uid"] as? String,
              let title = userInfo["title"] as? String,
              let summary = userInfo["summary"] as? String else { return }
        let actions = (userInfo["actions"] as? [String]) ?? []
        let at = (userInfo["at"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? .now
        Task { @MainActor in
            WatchSummaryStore.shared.receive(
                uid: uid, title: title, summary: summary, actions: actions, at: at)
        }
    }
}
