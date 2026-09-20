#if os(macOS)
import SwiftUI
import ArcaVoiceKit

/// The state machine behind ARCA's notch presence. The notch is where ARCA
/// lives on the Mac: idle eyes, meeting prompts, recording status, and
/// screenshot → action-plan offers all happen here.
@MainActor
@Observable
final class NotchAgent {
    enum Mode: Equatable {
        case idle
        case menu
        case meetingPrompt(String)
        case screenshotPrompt(URL)
        case readingCapture
        case planReady(String)
        /// A screenshot read on the phone reached this Mac via Handoff — shows
        /// the summary and, when `hasSchedule` is true, a "create the schedule
        /// now?" button instead of just an "open" one.
        case handoffReview(title: String, hasSchedule: Bool)
        case creatingSchedule
        case notice(String)
        /// A finished quest — happy face + sparkle, brief.
        case celebrate(String)
        case chat
        /// Dragging an image over the notch — "mouth" is open, awaiting drop.
        case dropTarget
        /// Hovering the notch — ARCA opens into the chat-log + to-do dashboard.
        case dashboard
    }

    private(set) var mode: Mode = .idle
    /// Where the cursor is relative to the notch, normalized -1…1 — the idle
    /// eyes follow it. Updated by the window controller's mouse monitor.
    var pointerLook: CGPoint = .zero
    /// Throttle stamp for the pointer-look monitor (15Hz cap — see
    /// NotchWindowController); not observable state.
    @ObservationIgnored var lastPointerLookAt = ContinuousClock.now - .seconds(1)
    /// The live conversation, present while `mode == .chat`.
    private(set) var chat: ChatSession?
    /// The window controller hooks this to resize the panel per mode.
    @ObservationIgnored var onModeChange: ((Mode) -> Void)?
    @ObservationIgnored private var pendingPlanSession: RecordingSession?
    /// The session a Handoff review is currently showing — separate from
    /// `pendingPlanSession` since the two prompts ("open the plan I just made"
    /// vs. "review what the phone just read") can never be on screen together.
    @ObservationIgnored private var pendingHandoffSession: RecordingSession?
    @ObservationIgnored private var autoDismissTask: Task<Void, Never>?

    // MARK: - Offers (called by watchers)

    func offerMeeting(label: String) {
        guard case .idle = mode, AppServices.shared.coordinator.phase == .idle else { return }
        set(.meetingPrompt(label), autoDismissAfter: 25)
    }

    func offerScreenshot(_ url: URL) {
        guard case .idle = mode, AppServices.shared.coordinator.phase == .idle else { return }
        set(.screenshotPrompt(url), autoDismissAfter: 15)
    }

    // MARK: - User actions

    func toggleMenu() {
        switch mode {
        case .idle: set(.menu, autoDismissAfter: 8)
        case .menu: set(.idle)
        default: break
        }
    }

    func acceptMeeting() {
        let pending = AppServices.shared.meetingDetector.pending
        let meetingApp = pending?.meetingApp
        AppServices.shared.meetingDetector.accept()
        set(.idle)
        // Ask who's here first. Only for detected meetings — a voice memo or a
        // hotkey capture still starts on the first click, because a prompt in
        // front of those is pure friction.
        AppServices.shared.presentParticipantPrep(
            meetingApp: meetingApp, label: pending?.label)
    }

    func dismissMeeting() {
        AppServices.shared.meetingDetector.dismiss()
        set(.idle)
    }

    func showNotice(_ message: String, seconds: TimeInterval = 6) {
        set(.notice(message), autoDismissAfter: seconds)
    }

    func startRecordingFromMenu() {
        set(.idle)
        AppServices.shared.startRecording()
    }

    func stopRecording() {
        AppServices.shared.stopRecording()
        set(.notice("Wrapping up — I'll let you know when the summary's ready"), autoDismissAfter: 6)
    }

    func acceptScreenshot(_ url: URL) {
        DebugTrace.log("acceptScreenshot \(url.lastPathComponent)")
        // Watchdog: a stuck vision call can't wedge the agent — it recovers to idle.
        set(.readingCapture, autoDismissAfter: 80)
        Task { @MainActor in
            guard let apiKey = ArcaCloud.anthropicKey, !apiKey.isEmpty else {
                DebugTrace.log("no anthropic key")
                set(.notice("Anthropic key needed — add it in Settings to create screenshot action plans."), autoDismissAfter: 6)
                return
            }
            do {
                DebugTrace.log("reading image bytes")
                // Downscale before upload: Retina screenshots are multi-MB and
                // large request bodies stall URLSession; a ~1600px JPEG keeps
                // text legible for vision while cutting bytes ~10x.
                let (data, mediaType) = try ImageDownscaler.jpeg(from: url, maxDimension: 1600)
                    ?? (Data(contentsOf: url), ClaudeVisionPlanner.mediaType(for: url))
                DebugTrace.log("prepared \(data.count) bytes (\(mediaType)); calling vision")
                let plan = try await ClaudeVisionPlanner(apiKey: apiKey)
                    .plan(imageData: data, mediaType: mediaType)
                DebugTrace.log("vision returned: \(plan.title)")
                guard let context = AppServices.shared.mainContext else { return }

                let record = RecordingSession(title: "📸 \(plan.title)", source: .screenshot)
                record.state = .ready
                let note = SessionNote()
                note.summaryMarkdown = plan.insightMarkdown
                note.actionItemsJSON = try? JSONEncoder().encode(plan.actionItems)
                record.note = note
                context.insert(record)
                try? context.save()

                pendingPlanSession = record
                set(.planReady(plan.offerLine), autoDismissAfter: 45)
            } catch {
                DebugTrace.log("vision failed: \(error)")
                set(.notice(UserFacingError.message(for: error)), autoDismissAfter: 8)
            }
        }
    }

    func dismissScreenshot() {
        NSLog("[ArcaVoice] notch: screenshot dismissed")
        set(.idle)
    }

    // MARK: - Handoff (a screenshot read on the phone, continued here)

    /// Called once RootView resolves a continued Handoff activity to an
    /// actual (now-synced) session. Brings the Mac forward so the review
    /// isn't just a silent notch change nobody notices.
    func presentHandoffReview(session: RecordingSession) {
        DebugTrace.log("handoff: presenting \(session.directoryName.prefix(8))")
        pendingHandoffSession = session
        let hasSchedule = !Self.pendingScheduleItems(for: session).isEmpty
        set(.handoffReview(title: session.title, hasSchedule: hasSchedule),
            autoDismissAfter: hasSchedule ? nil : 20)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The response to "지금 일정 만들어줄까?" — creates a calendar event for
    /// every dated action item the phone's read hasn't already scheduled.
    func confirmHandoffSchedule() {
        guard let session = pendingHandoffSession else { return }
        // Watchdog, same idea as acceptScreenshot's: a stuck EventKit/network
        // call can't wedge the notch on "creating" forever.
        set(.creatingSchedule, autoDismissAfter: 60)
        Task { @MainActor in
            var items = Self.decodeActionItems(for: session)
            var created = 0
            for index in items.indices {
                guard let due = items[index].due, items[index].calendarEventID == nil else { continue }
                do {
                    let eventID = try await CalendarEventCreator.create(
                        title: items[index].text, start: due,
                        description: session.note?.summaryMarkdown ?? "")
                    items[index].calendarEventID = eventID
                    created += 1
                } catch {
                    continue // one bad item shouldn't block the rest
                }
            }
            session.note?.actionItemsJSON = try? JSONEncoder().encode(items)
            session.touch()
            try? AppServices.shared.mainContext?.save()
            RelaySync.shared.scheduleSync()
            pendingHandoffSession = nil
            if created > 0 {
                set(.celebrate(L("일정 \(created)개 추가됨", "\(created) event\(created == 1 ? "" : "s") added")),
                    autoDismissAfter: 4)
            } else {
                set(.notice(L("일정을 만들지 못했어요 — 캘린더 접근을 확인해 주세요",
                              "Couldn't create the schedule — check calendar access")),
                    autoDismissAfter: 6)
            }
        }
    }

    func dismissHandoffReview() {
        pendingHandoffSession = nil
        set(.idle)
    }

    /// "열기" on a no-schedule handoff review — opens the saved plan like
    /// `openPlan()` does for a locally-read screenshot.
    func openHandoffSession() {
        if let session = pendingHandoffSession {
            AppServices.shared.sessionToOpen = session
        }
        pendingHandoffSession = nil
        set(.idle)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func decodeActionItems(for session: RecordingSession) -> [MeetingNotes.ActionItem] {
        guard let data = session.note?.actionItemsJSON,
              let items = try? JSONDecoder().decode([MeetingNotes.ActionItem].self, from: data) else {
            return []
        }
        return items
    }

    private static func pendingScheduleItems(for session: RecordingSession) -> [MeetingNotes.ActionItem] {
        decodeActionItems(for: session).filter { $0.due != nil && $0.calendarEventID == nil }
    }

    func openPlan() {
        if let session = pendingPlanSession {
            AppServices.shared.sessionToOpen = session
        }
        pendingPlanSession = nil
        set(.idle)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openApp() {
        set(.idle)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// ZONE flipped — announce it in the notch, then the idle eyes carry it.
    func zoneChanged(_ on: Bool) {
        switch mode {
        case .idle, .menu, .dashboard, .notice, .celebrate:
            set(.notice(on ? "🌙 ZONE on — I'm guarding your focus"
                           : "ZONE off — here's what happened"),
                autoDismissAfter: 3)
        default:
            break
        }
    }

    /// A task finished — flash the win in the notch (unless mid-interaction).
    func celebrate(_ title: String) {
        switch mode {
        case .idle, .menu, .dashboard, .notice, .celebrate:
            set(.celebrate(title), autoDismissAfter: 3.5)
        default:
            break
        }
    }

    // MARK: - Chat (mouth-drop + hotkey)

    /// Show the open-mouth drop zone while an image is dragged over the notch.
    func setDropTargeting(_ active: Bool) {
        if active {
            if case .chat = mode { return }
            set(.dropTarget)
        } else if case .dropTarget = mode {
            set(.idle)
        }
    }

    /// A screenshot was dropped into ARCA's mouth — open a chat about it.
    func startChat(withImage data: Data, mediaType: String = "image/jpeg", prompt: String? = nil) {
        autoDismissTask?.cancel()
        let session = ChatSession()
        chat = session
        set(.chat)
        session.begin(withImage: data, mediaType: mediaType, prompt: prompt)
    }

    /// Triggered by the hotkey: capture the whole screen and chat about it.
    func captureAndChat() {
        // Bounded like acceptScreenshot — a stalled grab must not pin the
        // notch on "reading" forever.
        set(.readingCapture, autoDismissAfter: 80)
        Task { @MainActor in
            guard let (data, mediaType) = await ScreenGrab.fullScreenJPEG() else {
                set(.notice("Screen capture failed — check Screen Recording permission"), autoDismissAfter: 6)
                return
            }
            startChat(withImage: data, mediaType: mediaType)
        }
    }

    func closeChat() {
        chat?.endConversation()
        chat = nil
        set(.idle)
    }

    // MARK: - Hover dashboard

    /// Mouse entered the notch — open the dashboard (unless mid-interaction).
    func hoverOpen() {
        switch mode {
        case .idle, .menu: set(.dashboard)
        default: break
        }
    }

    /// Mouse left the dashboard — close after a short grace so brief
    /// excursions (crossing the menu bar, overshooting an edge) don't slam it.
    func hoverClose() {
        guard mode == .dashboard else { return }
        autoDismissTask?.cancel()
        autoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, self?.mode == .dashboard else { return }
            self?.set(.idle)
        }
    }

    /// Pointer is roaming the open dashboard — cancel any pending close.
    func hoverStay() {
        guard mode == .dashboard else { return }
        autoDismissTask?.cancel()
    }

    /// From the dashboard, start a fresh typed chat (no image).
    func startBlankChat() {
        let session = ChatSession()
        chat = session
        set(.chat)
    }

    // MARK: - Internals

    private func set(_ newMode: Mode, autoDismissAfter seconds: TimeInterval? = nil) {
        autoDismissTask?.cancel()
        // This mode switch fires many times a session (idle ↔ chat ↔
        // dashboard) — kept under the 300ms UI ceiling so it stays snappy.
        withAnimation(.spring(duration: 0.3, bounce: 0.25)) {
            mode = newMode
        }
        onModeChange?(newMode)
        if let seconds {
            let target = newMode
            autoDismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, self?.mode == target else { return }
                // An ignored meeting prompt must release the detector, or
                // `pending` stays set and no meeting is ever detected again.
                if case .meetingPrompt = target {
                    AppServices.shared.meetingDetector.dismiss()
                }
                self?.set(.idle)
            }
        }
    }
}
#endif
