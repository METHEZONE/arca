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
}
