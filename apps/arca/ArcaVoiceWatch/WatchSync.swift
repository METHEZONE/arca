import Foundation
import WatchConnectivity

/// Ships finished recordings to the paired iPhone. WCSession file transfers
/// queue and survive the app closing — but the wrist deserves to know where
/// its recording is, so every transfer reports into `WatchTransferStatus`.
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
        Task { @MainActor in WatchTransferStatus.shared.began() }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        let pending = session.outstandingFileTransfers.count
        Task { @MainActor in WatchTransferStatus.shared.setOutstanding(pending) }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let failed = error != nil
        Task { @MainActor in WatchTransferStatus.shared.finished(failed: failed) }
    }

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
            WatchTransferStatus.shared.summaryArrived()
            WatchSummaryStore.shared.receive(
                uid: uid, title: title, summary: summary, actions: actions, at: at)
        }
    }
}

/// Where is my recording? Sending → on the iPhone → summary landed.
/// Purely perceptual state; the transfers themselves are WCSession's job.
@MainActor
@Observable
final class WatchTransferStatus {
    static let shared = WatchTransferStatus()

    /// Recordings still queued/moving to the iPhone.
    private(set) var sending = 0
    /// Delivered to the iPhone; summary hasn't come back yet.
    private(set) var awaitingSummary = false
    /// A transfer gave up (e.g. session invalidated) — shown once, cleared on next send.
    private(set) var sendFailed = false

    private var expireTask: Task<Void, Never>?

    func began() {
        sending += 1
        sendFailed = false
    }

    func setOutstanding(_ count: Int) {
        sending = max(sending, count)
    }

    func finished(failed: Bool) {
        sending = max(0, sending - 1)
        if failed {
            sendFailed = true
        } else {
            awaitingSummary = true
            // Long recordings take a while server-side; stop promising a
            // summary after 10 minutes rather than pinning hope forever.
            expireTask?.cancel()
            expireTask = Task {
                try? await Task.sleep(for: .seconds(600))
                guard !Task.isCancelled else { return }
                awaitingSummary = false
            }
        }
    }

    func summaryArrived() {
        expireTask?.cancel()
        awaitingSummary = false
    }
}
