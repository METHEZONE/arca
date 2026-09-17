#if os(iOS)
import Foundation
import SwiftData
import WatchConnectivity
import ArcaVoiceKit

/// The phone's side of the wrist. Receives Watch recordings and runs them
/// through the same pipeline as phone recordings (no live pass — straight to
/// the quality pass); mints live-talk secrets; keeps the wrist's to-do list and
/// body read current; files conversations the user had on the watch.
final class PhoneWatchSync: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = PhoneWatchSync()

    private var container: ModelContainer?
    /// Application context is one "latest value" dictionary; vitals and
    /// to-dos each keep their last payload so an update to one doesn't wipe
    /// the other off the wrist.
    private var lastVitals: [String: Any]?
    private var lastTodos: [[String: Any]]?

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
        var vitals: [String: Any] = ["isLive": isLive, "label": label]
        if let ringScore { vitals["ringScore"] = ringScore }
        if let nextWindowLabel { vitals["nextWindow"] = nextWindowLabel }
        if let sleepMinutes { vitals["sleepMinutes"] = sleepMinutes }
        lastVitals = vitals
        pushContext()
    }

    /// The open to-do list for the wrist's second page. Called on activation,
    /// when the app comes to the foreground, and after the wrist ticks one off.
    @MainActor
    func sendTodos() {
        guard let context = container?.mainContext else { return }
        var descriptor = FetchDescriptor<TodoTask>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 200
        let tasks = ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.state == .open || $0.state == .needsUser }
            .sorted { ($0.dueAt ?? .distantFuture, $0.createdAt) < ($1.dueAt ?? .distantFuture, $1.createdAt) }
            .prefix(25)
        lastTodos = tasks.map(Self.wire)
        pushContext()
    }

    private static func wire(_ task: TodoTask) -> [String: Any] {
        var item: [String: Any] = ["id": task.uid.uuidString, "title": task.title]
        if let due = task.dueAt { item["due"] = due.timeIntervalSince1970 }
        return item
    }

    private func pushContext() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        var context: [String: Any] = [:]
        if let lastVitals { context["vitals"] = lastVitals }
        if let lastTodos { context["todos"] = lastTodos }
        guard !context.isEmpty else { return }
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
                 error: Error?) {
        guard activationState == .activated else { return }
        Task { @MainActor in self.sendTodos() }
    }

    /// Requests that need an answer now: a live-talk secret, the to-do list.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        // WatchConnectivity's reply closure isn't Sendable; it's only ever
        // called once, from the task below.
        nonisolated(unsafe) let reply = replyHandler
        switch message["type"] as? String {
        case "realtimeSecret":
            Task { @MainActor in
                let ownerName = UserDefaults.standard.string(forKey: "ownerName") ?? "Me"
                let instructions = RealtimeSecretMinter.instructions(
                    context: self.container?.mainContext, ownerName: ownerName)
                do {
                    let secret = try await RealtimeSecretMinter.mint(instructions: instructions)
                    reply(["secret": secret.value, "expiresAt": secret.expiresAt.timeIntervalSince1970])
                } catch {
                    reply(["error": error.localizedDescription])
                }
            }
        case "todos":
            Task { @MainActor in
                self.sendTodos()
                reply(["todos": self.lastTodos ?? []])
            }
        default:
            reply([:])
        }
    }

    /// Results coming back from the wrist. Values are pulled out here so only
    /// `Sendable` primitives cross to the main actor.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        switch userInfo["type"] as? String {
        case "deepMeasure":
            guard let startedAt = (userInfo["startedAt"] as? Double).map(Date.init(timeIntervalSince1970:)),
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

        case "watchTalk":
            // A conversation held on the wrist joins the chat history, one
            // conversation per day, so it reads like any other chat.
            let turns = (userInfo["turns"] as? [[String: String]]) ?? []
            let at = (userInfo["at"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? .now
            guard !turns.isEmpty else { return }
            Task { @MainActor in
                guard let context = self.container?.mainContext else { return }
                let day = DateFormatter()
                day.dateFormat = "yyyy-MM-dd"
                let conversationId = "watch-\(day.string(from: at))"
                for (index, turn) in turns.enumerated() {
                    guard let role = turn["role"], let text = turn["text"], !text.isEmpty else { continue }
                    let entry = ChatLogEntry(role: role, text: text, conversationId: conversationId)
                    entry.createdAt = at.addingTimeInterval(Double(index))
                    context.insert(entry)
                }
                try? context.save()
            }

        case "todoDone":
            guard let raw = userInfo["uid"] as? String, let uid = UUID(uuidString: raw) else { return }
            Task { @MainActor in
                guard let context = self.container?.mainContext else { return }
                let tasks = (try? context.fetch(FetchDescriptor<TodoTask>())) ?? []
                if let task = tasks.first(where: { $0.uid == uid }) {
                    task.state = .done
                    task.updatedAt = .now
                    try? context.save()
                }
                self.sendTodos()
            }

        default:
            break
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
        let isMemo = (file.metadata?["kind"] as? String) == "memo"

        Task { @MainActor in
            guard let container = self.container else { return }
            let context = container.mainContext

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: ArcaLanguageResolver.isKorean ? "ko_KR" : "en_US")
            formatter.dateFormat = ArcaLanguageResolver.isKorean ? "M월 d일 HH:mm" : "MMM d, HH:mm"
            let stamp = formatter.string(from: startedAt)
            let record = RecordingSession(
                title: isMemo ? L("⌚️ 빠른 메모 \(stamp)", "⌚️ Quick memo \(stamp)")
                              : L("⌚️ 워치 녹음 \(stamp)", "⌚️ Watch recording \(stamp)"),
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
