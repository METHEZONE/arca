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
    @ObservationIgnored private var screenshotWatcher: ScreenshotWatcher?
    @ObservationIgnored private let hotkeyMonitor = HotkeyMonitor()
    @ObservationIgnored private var zoneReportWindow: NSWindow?
    #endif

    var mainContext: ModelContext? { container?.mainContext }

    var ownerName: String {
        UserDefaults.standard.string(forKey: "ownerName") ?? "Me"
    }

    func configure(container: ModelContainer) {
        self.container = container
        RelaySync.shared.configure(container: container)
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
            self.watchZoneReport()
            TaskEngine.shared.retryFailedClassifications(context: container.mainContext)
            FinalPassRunner.retryFailed(context: container.mainContext,
                                        ownerName: self.ownerName,
                                        languageHints: TranscriptionPrefs.languageHints)

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
        var small = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        small.httpMethod = "POST"
        small.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        small.setValue("application/json", forHTTPHeaderField: "content-type")
        small.setValue(KeychainStore.get(.anthropic) ?? "", forHTTPHeaderField: "x-api-key")
        small.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "claude-sonnet-5", "max_tokens": 16,
            "messages": [["role": "user", "content": "hi"]],
        ])
        await hit("POST-small-anthropic", small)
    }
    #endif

    func startRecording(meetingApp: String? = nil) {
        Task { @MainActor in
            await coordinator.start(
                locale: TranscriptionPrefs.liveLocale,
                languageHints: TranscriptionPrefs.languageHints,
                meetingApp: meetingApp)
        }
    }

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
        }
    }
}
