#if os(iOS)
import Foundation
import SwiftData
import WatchConnectivity
import ArcaVoiceKit

/// Receives Watch recordings and runs them through the same pipeline as
/// phone recordings (no live pass — straight to the quality pass).
final class PhoneWatchSync: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = PhoneWatchSync()

    private var container: ModelContainer?

    func configure(container: ModelContainer) {
        self.container = container
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Ships a finished summary back to the Watch. transferUserInfo queues
    /// and survives both apps being closed — the Watch shows it on next open.
    func sendSummary(uid: String, title: String, summaryMarkdown: String, actionItems: [String]) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        WCSession.default.transferUserInfo([
            "type": "summary",
            "uid": uid,
            "title": title,
            "summary": summaryMarkdown,
            "actions": actionItems,
            "at": Date.now.timeIntervalSince1970,
        ])
    }

    /// Pushes the wrist a compact read on the body.
    ///
    /// `updateApplicationContext` rather than a queued transfer: this is "latest
    /// state", and a new value should replace the old one instead of stacking up
    /// behind it. App Groups don't span iPhone and Watch, so the widget snapshot
    /// the phone writes locally is invisible over here — it has to be sent.
    func sendVitalsSummary(ringScore: Int?, isLive: Bool, label: String,
                           nextWindowLabel: String?, sleepMinutes: Int?) {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated else { return }
        var context: [String: Any] = ["type": "vitals", "isLive": isLive, "label": label]
        if let ringScore { context["ringScore"] = ringScore }
        if let nextWindowLabel { context["nextWindow"] = nextWindowLabel }
        if let sleepMinutes { context["sleepMinutes"] = sleepMinutes }
        try? WCSession.default.updateApplicationContext(context)
    }

    /// Asks the Watch to run a focus measurement.
    ///
    /// Returns false when the Watch app isn't reachable — WatchConnectivity
    /// cannot launch it, so the honest move is to report that and let the UI tell
    /// the user to open ARCA on their wrist, rather than spin a progress
    /// indicator on a request nothing will ever answer.
    func requestDeepMeasure(seconds: Int) -> Bool {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { return false }
        WCSession.default.sendMessage(
            ["type": "startDeepMeasure", "seconds": seconds],
            replyHandler: nil,
            errorHandler: { error in
                Task { @MainActor in
                    VitalsEngine.shared.failMeasuring(
                        "애플워치에 요청을 보내지 못했어요: \(error.localizedDescription)")
                }
            })
        return true
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}

    /// Results coming back from the wrist. Values are pulled out here so only
    /// `Sendable` primitives cross to the main actor.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard (userInfo["type"] as? String) == "deepMeasure",
              let startedAt = (userInfo["startedAt"] as? Double).map(Date.init(timeIntervalSince1970:)),
              let meanHR = userInfo["meanHR"] as? Double,
              let minHR = userInfo["minHR"] as? Double,
              let maxHR = userInfo["maxHR"] as? Double else { return }
        let seconds = (userInfo["seconds"] as? Int) ?? 0
        let hrvSDNN = userInfo["hrvSDNN"] as? Double
        let beatIntervalSD = userInfo["beatIntervalSD"] as? Double

        Task { @MainActor in
            VitalsEngine.shared.recordDeepMeasure(
                startedAt: startedAt, seconds: seconds,
                meanHR: meanHR, minHR: minHR, maxHR: maxHR,
                hrvSDNN: hrvSDNN, beatIntervalSD: beatIntervalSD)
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The incoming file is deleted when this method returns — move it now.
        let directoryName = UUID().uuidString
        let directory = SessionPaths.directory(for: directoryName)
        let destination = directory.appendingPathComponent("microphone.m4a")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file.fileURL, to: destination)
        } catch {
            return
        }
        let duration = (file.metadata?["duration"] as? Double) ?? 0
        let startedAt = (file.metadata?["createdAt"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? .now

        Task { @MainActor in
            guard let container = self.container else { return }
            let context = container.mainContext

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.dateFormat = "MMM d, HH:mm"
            let record = RecordingSession(
                title: "⌚️ \(formatter.string(from: startedAt)) recording",
                source: .watchMemo,
                directoryName: directoryName,
                createdAt: startedAt)
            record.duration = duration
            record.state = .processing
            record.audioAssets.append(AudioAsset(
                channel: .microphone,
                relativePath: "\(directoryName)/microphone.m4a",
                duration: duration))
            record.note = SessionNote()
            context.insert(record)
            try? context.save()

            FinalPassRunner.run(
                record: record,
                files: [.microphone: destination],
                userNotes: nil,
                ownerName: UserDefaults.standard.string(forKey: "ownerName") ?? "Me",
                languageHints: TranscriptionPrefs.languageHints)
        }
    }
}
#endif
