import Foundation
import WatchConnectivity

/// Ships finished recordings to the paired iPhone. WCSession file transfers
/// queue and survive the app closing — but the wrist deserves to know where
/// its recording is, so every transfer reports into `WatchTransferStatus`.
final class WatchSync: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchSync()

    private var didSweepOrphans = false

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

    /// Ships a finished focus measurement to the iPhone, which scores it against
    /// the user's baselines. `transferUserInfo` queues, so a phone out of range
    /// just means the result lands a little later.
    @discardableResult
    func send(deepMeasureStartedAt startedAt: Date, seconds: Int,
              meanHR: Double, minHR: Double, maxHR: Double,
              hrvSDNN: Double?, beatIntervalSD: Double?) -> Bool {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated else { return false }
        var payload: [String: Any] = [
            "type": "deepMeasure",
            "startedAt": startedAt.timeIntervalSince1970,
            "seconds": seconds,
            "meanHR": meanHR,
            "minHR": minHR,
            "maxHR": maxHR,
        ]
        if let hrvSDNN { payload["hrvSDNN"] = hrvSDNN }
        if let beatIntervalSD { payload["beatIntervalSD"] = beatIntervalSD }
        WCSession.default.transferUserInfo(payload)
        return true
    }

    /// The iPhone asking the wrist to measure. Only arrives while the Watch app
    /// is open — WatchConnectivity can't launch it — which is why the phone's UI
    /// falls back to telling the user to open it.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard (message["type"] as? String) == "startDeepMeasure" else { return }
        let seconds = (message["seconds"] as? Int) ?? 180
        WatchDeepMeasure.shared.start(seconds: seconds)
    }

    /// The body read the phone computed. Application context is "latest value
    /// wins", which is exactly right for a summary, and it's delivered on the
    /// next launch even if the Watch app wasn't running when it was set.
    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        applyVitals(context)
    }

    /// Picks up whatever the phone last set, so the wrist isn't blank on launch.
    func loadLatestVitals() {
        guard WCSession.isSupported() else { return }
        applyVitals(WCSession.default.receivedApplicationContext)
    }

    private func applyVitals(_ context: [String: Any]) {
        guard (context["type"] as? String) == "vitals" else { return }
        let score = context["ringScore"] as? Int
        let isLive = (context["isLive"] as? Bool) ?? false
        let label = (context["label"] as? String) ?? ""
        let nextWindow = context["nextWindow"] as? String
        let sleepMinutes = context["sleepMinutes"] as? Int
        Task { @MainActor in
            WatchVitalsStatus.shared.receive(ringScore: score, isLive: isLive, label: label,
                                             nextWindow: nextWindow, sleepMinutes: sleepMinutes)
        }
    }

    /// A recording only reaches the phone from `WatchRecorder.stopAndSend()`.
    /// If the Watch app died before that ran — force quit, battery saver,
    /// watchdog — the audio is still sitting in Documents with nobody to hand
    /// it over. Sweep those up so a lost meeting becomes a late one.
    ///
    /// Runs once per launch, right after activation (transfers can only be
    /// queued on an activated session), and before any recording can have
    /// started. A no-op when there is nothing stranded.
    private func sweepOrphans(_ session: WCSession) {
        guard !didSweepOrphans else { return }
        didSweepOrphans = true

        // File transfers survive app launches, so anything already queued from
        // a previous run would otherwise be sent twice. Matched by name
        // because WatchConnectivity may hand back its own copy's URL.
        let queued = Set(session.outstandingFileTransfers.map { $0.file.fileURL.lastPathComponent })
        for url in WatchRecordingStore.orphanedRecordings()
        where !queued.contains(url.lastPathComponent) {
            NSLog("[ArcaVoice] watch: resending stranded recording %@", url.lastPathComponent)
            send(file: url,
                 duration: WatchRecordingStore.estimatedDuration(of: url),
                 createdAt: WatchRecordingStore.createdAt(of: url))
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        let pending = session.outstandingFileTransfers.count
        Task { @MainActor in WatchTransferStatus.shared.setOutstanding(pending) }
        guard activationState == .activated else { return }
        sweepOrphans(session)
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let failed = error != nil
        let name = fileTransfer.file.fileURL.lastPathComponent
        if failed {
            // Left on disk on purpose: the next launch's sweep retries it.
            NSLog("[ArcaVoice] watch: transfer of %@ failed: %@", name,
                  "\(error.map(String.init(describing:)) ?? "unknown")")
        } else {
            // Recordings live in Documents now, so nothing else reclaims them.
            // A confirmed handoff is the only safe moment to delete. Resolved
            // against our own directory by name so this can't touch (or miss)
            // WatchConnectivity's internal copy.
            let local = WatchRecordingStore.directory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: local)
        }
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
