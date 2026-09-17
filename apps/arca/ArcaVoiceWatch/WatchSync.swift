import Foundation
import WatchConnectivity

/// Ships finished recordings to the paired iPhone. WCSession file transfers
/// queue and survive the app closing — but the wrist deserves to know where
/// its recording is, so every transfer reports into `WatchTransferStatus`.
///
/// Also the wrist's line to the phone for everything that needs the phone's
/// keys or store: live-talk secrets, to-dos, and conversation transcripts.
final class WatchSync: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchSync()

    private var didSweepOrphans = false

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// `kind` tells the phone how to title it: a meeting recording or a quick
    /// held-button memo.
    func send(file: URL, duration: TimeInterval, createdAt: Date, kind: String = "meeting") {
        WCSession.default.transferFile(file, metadata: [
            "duration": duration,
            "createdAt": createdAt.timeIntervalSince1970,
            "kind": kind,
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

    /// A finished live conversation, for the phone's chat history.
    func send(talk turns: [[String: String]], startedAt: Date) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        WCSession.default.transferUserInfo([
            "type": "watchTalk",
            "turns": turns,
            "at": startedAt.timeIntervalSince1970,
        ])
    }

    /// A to-do ticked off on the wrist. Queued, so it lands even out of range.
    func send(todoDone uid: String) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        WCSession.default.transferUserInfo(["type": "todoDone", "uid": uid])
    }

    /// Asks the phone for a short-lived Realtime client secret. Needs the phone
    /// reachable right now — a live conversation can't wait for a queue.
    func requestRealtimeSecret() async throws -> String {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isReachable else {
            throw LiveTalkError.phoneUnreachable
        }
        return try await withCheckedThrowingContinuation { continuation in
            session.sendMessage(["type": "realtimeSecret"], replyHandler: { reply in
                if let secret = reply["secret"] as? String, !secret.isEmpty {
                    continuation.resume(returning: secret)
                } else {
                    continuation.resume(throwing: LiveTalkError.phone(
                        (reply["error"] as? String) ?? L("아이폰이 대화 세션을 못 열었어요", "Your iPhone couldn't open a talk session")))
                }
            }, errorHandler: { error in
                continuation.resume(throwing: LiveTalkError.phone(error.localizedDescription))
            })
        }
    }

    /// Pulls the open to-do list when the page appears; the phone also pushes
    /// it as application context, so this is freshness, not the only source.
    func requestTodos() {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["type": "todos"], replyHandler: { reply in
            guard let raw = reply["todos"] as? [[String: Any]] else { return }
            let items = raw.compactMap(Self.todoItem)
            Task { @MainActor in WatchTodoStore.shared.receive(items) }
        }, errorHandler: { _ in })
    }

    /// The iPhone asking the wrist to measure. Only arrives while the Watch app
    /// is open — WatchConnectivity can't launch it — which is why the phone's UI
    /// falls back to telling the user to open it.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard (message["type"] as? String) == "startDeepMeasure" else { return }
        let seconds = (message["seconds"] as? Int) ?? 180
        WatchDeepMeasure.shared.start(seconds: seconds)
    }

    /// Latest-value state from the phone: the body read, and the open to-dos.
    /// One dictionary carries both so neither overwrites the other; the old
    /// single-purpose `type: vitals` shape is still understood.
    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        applyContext(context)
    }

    /// Picks up whatever the phone last set, so the wrist isn't blank on launch.
    func loadLatestVitals() {
        guard WCSession.isSupported() else { return }
        applyContext(WCSession.default.receivedApplicationContext)
    }

    private func applyContext(_ context: [String: Any]) {
        if let vitals = context["vitals"] as? [String: Any] {
            applyVitals(vitals)
        } else if (context["type"] as? String) == "vitals" {
            applyVitals(context)
        }
        if let raw = context["todos"] as? [[String: Any]] {
            let items = raw.compactMap(Self.todoItem)
            Task { @MainActor in WatchTodoStore.shared.receive(items) }
        }
    }

    /// Decoded here so only a Sendable value crosses to the main actor.
    private static func todoItem(_ raw: [String: Any]) -> WatchTodoStore.Item? {
        guard let id = raw["id"] as? String, let title = raw["title"] as? String else { return nil }
        let due = (raw["due"] as? Double).map(Date.init(timeIntervalSince1970:))
        return WatchTodoStore.Item(id: id, title: title, due: due)
    }

    private func applyVitals(_ context: [String: Any]) {
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
