import SwiftUI
import SwiftData
import ArcaVoiceKit

/// Process-wide services. The recording coordinator lives here (not in a view)
/// because on macOS the notch agent must drive recordings with no window open.
@MainActor
@Observable
final class AppServices {
    static let shared = AppServices()

    let coordinator = RecordingCoordinator()
    private(set) var container: ModelContainer?
    /// Set by ambient surfaces (notch/island) to ask the main UI to open a session.
    var sessionToOpen: RecordingSession?
    /// Deep-link/App-Intent routing: "talk" | "record" | "chat" — consumed by RootView.
    var pendingRoute: String?
    /// Startup/config warning shown once by RootView instead of crashing.
    var startupNotice: String?

    #if os(macOS)
    let meetingDetector = MeetingDetector()
    let notch = NotchAgent()
    let zone = ZoneEngine()
    let dayLog = DayLogEngine()
    @ObservationIgnored private var notchWindow: NotchWindowController?
    @ObservationIgnored private var floating: FloatingCompanionController?
    @ObservationIgnored private var screenshotWatcher: ScreenshotWatcher?
    @ObservationIgnored private let hotkeyMonitor = HotkeyMonitor()
    @ObservationIgnored private var zoneReportWindow: NSWindow?
    @ObservationIgnored private var participantPrepWindow: NSWindow?
    #endif
    /// Shared by the pre-recording sheet on both platforms.
    let participantPrep = ParticipantPrep()

    var mainContext: ModelContext? { container?.mainContext }

    var ownerName: String {
        AccountDefaults.string("ownerName") ?? UserDefaults.standard.string(forKey: "ownerName") ?? "Me"
    }

    /// The name ARCA addresses the user by. Lives here rather than in a
    /// Mac-only view model so both apps greet them identically.
    var ownerDisplayName: String {
        let trimmed = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "Me" else { return "민성님" }
        return trimmed.hasSuffix("님") ? trimmed : "\(trimmed)님"
    }

    func configure(container: ModelContainer) {
        self.container = container
        RelaySync.shared.configure(container: container)
        // Body + focus tracking. Starts read-only and battery-free: on iOS it
        // queries what the Watch already wrote to Apple Health, on macOS it only
        // profiles the app-switch timeline. It never prompts for Health access
        // on its own — that's asked for in Settings, or during onboarding.
        if !ArcaEdition.isBeta { VitalsEngine.shared.configure() }
        // Opt-in and off by default, so this only ever re-arms an alarm the user
        // asked for. It also self-disables if the notification prompt is denied.
        Task { await MorningNotifier.reschedule() }
        // Both platforms: a recording whose cloud pass didn't land keeps its
        // on-device transcript and gets retried when the network returns. This
        // used to be a Mac-only, launch-only sweep, so a phone recording that
        // failed to upload stayed un-summarized until the app was force-quit.
        PassRetryScheduler.shared.start(
            container: container,
            ownerName: { [weak self] in self?.ownerName ?? "Me" },
            languageHints: { TranscriptionPrefs.languageHints })
        #if os(iOS)
        // Dynamic Island buttons post this; LiveActivityIntents run in-process.
        NotificationCenter.default.addObserver(
            forName: .arcaToggleRecording, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.coordinator.phase == .idle {
                    self.startRecording()
                } else {
                    self.stopRecording()
                }
            }
        }
        #endif
        #if os(macOS)
        DebugTrace.install()
        zone.configure(container: container)
        dayLog.configure(container: container)
        #endif

        #if os(macOS)
        // Window + watchers after the run loop is up (NSApp must be ready).
        Task { @MainActor in
            if ProcessInfo.processInfo.environment["ARCA_NO_NOTCH"] == nil {
                self.notchWindow = NotchWindowController(
                    agent: self.notch, coordinator: self.coordinator, container: container)
            }
            // The free-floating ARCA: on by default, hideable from its menu or Settings.
            if UserDefaults.standard.object(forKey: FloatingCompanionController.enabledKey) as? Bool ?? true {
                self.floating = FloatingCompanionController(services: self)
            }
            self.watchZoneReport()
            TaskEngine.shared.retryFailedClassifications(context: container.mainContext)

            self.meetingDetector.onDetect = { [weak self] meeting in
                self?.notch.offerMeeting(label: meeting.label)
            }
            self.meetingDetector.start { [weak self] in
                (self?.coordinator.phase ?? .idle) != .idle
            }

            self.screenshotWatcher = ScreenshotWatcher { [weak self] url in
                self?.notch.offerScreenshot(url)
            }
            self.screenshotWatcher?.start()

            // Global hotkey (default: right-⌘ double-tap) → capture screen + chat.
            self.hotkeyMonitor.onTrigger = { [weak self] in
                self?.notch.captureAndChat()
            }
            self.hotkeyMonitor.start()

            if let startupNotice = self.startupNotice {
                self.notch.showNotice(startupNotice, seconds: 10)
            } else if !EngineFactory.hasSummarizerKey {
                self.notch.showNotice("Add an Anthropic or OpenAI key in Settings to enable AI summaries and action plans.", seconds: 8)
            }

            // Bring-up hook: ARCA_SELFTEST_IMAGE=<path> runs the screenshot→plan
            // flow once at launch, no click needed. Deterministic verification.
            if let path = ProcessInfo.processInfo.environment["ARCA_SELFTEST_IMAGE"] {
                self.notch.acceptScreenshot(URL(fileURLWithPath: path))
            }
            if let path = ProcessInfo.processInfo.environment["ARCA_SELFTEST_CHAT"],
               let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                self.notch.startChat(withImage: data)
            }
            if ProcessInfo.processInfo.environment["ARCA_NETTEST"] != nil {
                Task { await Self.networkSelfTest() }
            }
            // Headless repair: ARCA_RECOVER=free|paid rebuilds every transcript
            // whose audio survived. Same code path as the library button, just
            // reachable without a click so a recovery can be run and watched
            // from a terminal.
            if let mode = ProcessInfo.processInfo.environment["ARCA_RECOVER"] {
                self.runHeadlessRecovery(mode: mode, container: container)
            }
            if ProcessInfo.processInfo.environment["ARCA_SELFTEST_DASHBOARD"] != nil {
                self.notch.hoverOpen()
            }
            if ProcessInfo.processInfo.environment["ARCA_SELFTEST_ZONEREPORT"] != nil {
                self.zone.seedDemoReport()
            }
        }
        #endif
    }

    #if os(macOS)
    // MARK: - Pre-recording participants

    /// Asks who's in the meeting, then starts recording.
    ///
    /// Its own window rather than something in the notch panel: that panel is a
    /// `.nonactivatingPanel` so it never steals focus from the meeting the user
    /// is joining — which also means a text field inside it would never get key
    /// focus, and this screen is mostly a text field.
    func presentParticipantPrep(meetingApp: String?, label: String?) {
        participantPrep.reset()
        let start: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            let planned = self.participantPrep.participants
            self.participantPrepWindow?.close()
            self.startRecording(meetingApp: meetingApp, participants: planned)
        }
        let cancel: @MainActor () -> Void = { [weak self] in
            self?.participantPrepWindow?.close()
        }

        let view = ParticipantPrepView(
            prep: participantPrep, meetingLabel: label,
            ownerName: ownerName, onStart: start, onCancel: cancel)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = L("참석자", "Participants")
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.participantPrepWindow = nil }
        }
        participantPrepWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Headless recovery

    /// Rebuilds missing transcripts and reports progress to the trace log.
    ///
    /// Exists so a repair can be driven from a terminal and watched to
    /// completion — a rebuild of hours of audio is not something to start from a
    /// button and hope about, and the local engine gives no network activity to
    /// watch for.
    private func runHeadlessRecovery(mode: String, container: ModelContainer) {
        let engine: TranscriptionEngine = mode.lowercased() == "paid" ? .cloudDiarized : .localFree
        let context = container.mainContext
        let targets = FinalPassRunner.recoverable(context: context)
        let minutes = Int(FinalPassRunner.billableAudioSeconds(targets) / 60)
        DebugTrace.log("recover: engine=\(engine.rawValue) sessions=\(targets.count) audio=\(minutes)min")
        for record in targets {
            DebugTrace.log("recover: queued \(record.directoryName.prefix(8)) \(Int(record.duration))s \(record.title)")
        }
        let started = FinalPassRunner.recoverAll(
            context: context, ownerName: ownerName,
            languageHints: TranscriptionPrefs.languageHints, engine: engine)
        DebugTrace.log("recover: started \(started)")

        // Poll rather than await: each rebuild is its own detached task, and the
        // point of this hook is a log line per completion.
        Task { @MainActor in
            var remaining = started
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(10))
                let left = FinalPassRunner.recoverable(context: context)
                if left.count != remaining {
                    let done = targets.filter { !left.contains($0) }
                    for record in done {
                        DebugTrace.log("recover: DONE \(record.directoryName.prefix(8)) segments=\(record.segments.count) title=\(record.title)")
                    }
                    remaining = left.count
                    DebugTrace.log("recover: remaining \(remaining)")
                }
            }
            DebugTrace.log("recover: ALL DONE")
        }
    }

    // MARK: - ZONE report window

    /// Presents/dismisses the end-of-ZONE report window off `zone.showReport`.
    /// The notch has no SwiftUI presentation context, so the report gets its
    /// own window. Re-arms itself: Observation's onChange fires only once.
    private func watchZoneReport() {
        withObservationTracking {
            _ = zone.showReport
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.zone.showReport {
                    self.presentZoneReport()
                } else {
                    self.zoneReportWindow?.close()
                }
                self.watchZoneReport()
            }
        }
    }

    private func presentZoneReport() {
        if zoneReportWindow == nil {
            let hosting = NSHostingController(rootView: ZoneReportView(zone: zone))
            let window = NSWindow(contentViewController: hosting)
            window.title = "ZONE Report"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.zoneReportWindow = nil
                    self?.zone.showReport = false
                }
            }
            zoneReportWindow = window
        }
        zoneReportWindow?.center()
        zoneReportWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Isolates whether the app can do outbound network at all, GET vs large POST.
    static func networkSelfTest() async {
        func hit(_ label: String, _ request: URLRequest) async {
            DebugTrace.log("nettest \(label): start")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                DebugTrace.log("nettest \(label): OK \(code), \(data.count) bytes")
            } catch {
                DebugTrace.log("nettest \(label): ERROR \(error)")
            }
        }
        await hit("GET-example", URLRequest(url: URL(string: "https://example.com")!))

        // Large POST to a neutral echo endpoint: isolates "big body" from "anthropic".
        var bigEcho = URLRequest(url: URL(string: "https://httpbin.org/post")!)
        bigEcho.httpMethod = "POST"
        bigEcho.setValue("application/json", forHTTPHeaderField: "content-type")
        let blob = String(repeating: "A", count: 150_000)
        let bigBody = try? JSONSerialization.data(withJSONObject: ["data": blob])
        DebugTrace.log("nettest POST-big-echo: body=\(bigBody?.count ?? 0)")
        await hit("POST-big-echo-httpBody", { var r = bigEcho; r.httpBody = bigBody; return r }())
        if let bigBody {
            DebugTrace.log("nettest POST-big-echo-upload: start")
            do {
                let (d, resp) = try await URLSession.shared.upload(for: bigEcho, from: bigBody)
                DebugTrace.log("nettest POST-big-echo-upload: OK \((resp as? HTTPURLResponse)?.statusCode ?? -1), \(d.count) bytes")
            } catch {
                DebugTrace.log("nettest POST-big-echo-upload: ERROR \(error)")
            }
        }
        var small = URLRequest(url: ArcaCloud.anthropicMessagesURL)
        small.httpMethod = "POST"
        small.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        small.setValue("application/json", forHTTPHeaderField: "content-type")
        small.setValue(ArcaCloud.anthropicKey ?? "", forHTTPHeaderField: "x-api-key")
        small.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "claude-sonnet-5", "max_tokens": 16,
            "messages": [["role": "user", "content": "hi"]],
        ])
        await hit("POST-small-anthropic", small)
    }
    #endif

    func startRecording(meetingApp: String? = nil,
                        participants: [MeetingParticipant] = []) {
        Task { @MainActor in
            // Set before `start` — the live transcriber is built inside it and
            // takes the names as expected vocabulary.
            coordinator.plannedParticipants = participants
            await coordinator.start(
                locale: TranscriptionPrefs.liveLocale,
                languageHints: TranscriptionPrefs.languageHints,
                meetingApp: meetingApp)
            reportRecordingState()
        }
    }

    /// Mirrors recording state into the device heartbeat so the other device can
    /// show it. Reads the coordinator rather than assuming, because a start can
    /// fail and a heartbeat claiming "recording" would then be a lie.
    private func reportRecordingState() {
        #if os(macOS)
        let zoneStartedAt = zone.isActive ? zone.startedAt : nil
        #else
        let zoneStartedAt: Date? = nil
        #endif
        DevicePresence.reportActivity(zoneStartedAt: zoneStartedAt,
                                      isRecording: coordinator.phase != .idle)
    }

    #if os(macOS)
    func setFloatingCompanion(enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: FloatingCompanionController.enabledKey)
        if enabled {
            if floating == nil { floating = FloatingCompanionController(services: self) }
        } else {
            floating?.close()
            floating = nil
        }
    }
    #endif

    func stopRecording() {
        Task { @MainActor in
            guard let mainContext else {
                // No store to save into — still never leave the UI recording.
                coordinator.forceReset()
                return
            }
            // Belt-and-braces: if stop somehow wedges past its own timeouts,
            // yank the coordinator back to idle so the timer can't run forever.
            let watchdog = Task { @MainActor [coordinator] in
                try? await Task.sleep(for: .seconds(40))
                if coordinator.phase != .idle { coordinator.forceReset() }
            }
            if let saved = await coordinator.stop(modelContext: mainContext, ownerName: ownerName) {
                sessionToOpen = saved
            }
            watchdog.cancel()
            reportRecordingState()
        }
    }
}
