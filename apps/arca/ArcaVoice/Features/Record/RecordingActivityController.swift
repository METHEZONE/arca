#if os(iOS)
import Foundation
@preconcurrency import ActivityKit
import ArcaVoiceKit

/// Owns ARCA's single Live Activity. Ambient "companion" presence starts when
/// the app comes to the foreground and simply switches into "recording" mode
/// during a session — so ARCA (almost) never leaves the Dynamic Island.
@MainActor
final class RecordingActivityController {
    static let shared = RecordingActivityController()

    private var activity: Activity<RecordingActivityAttributes>?
    private var noteTask: Task<Void, Never>?
    /// Updates run one after another. Fired as independent tasks, a late
    /// "recording · 12 segments" could land after "recording stopped" and the
    /// island kept saying 듣고 있어요 with nothing recording.
    private var chain: Task<Void, Never>?

    private func send(_ state: RecordingActivityAttributes.ContentState) {
        let previous = chain
        chain = Task { @MainActor [weak self] in
            await previous?.value
            await self?.activity?.update(ActivityContent(state: state, staleDate: Self.staleDate))
        }
    }

    /// Rotates the resting pose while the app is alive, so the island shows
    /// ARCA eating, coding, napping… instead of one frozen face.
    private var poseTask: Task<Void, Never>?

    /// A resting state with a pose that fits the hour.
    private func resting(detail: String? = nil) -> RecordingActivityAttributes.ContentState {
        RecordingActivityAttributes.ContentState(mode: "companion", startedAt: .now,
                                                 detail: detail, pose: Self.pose())
    }

    /// Meals at meal times, sleep at night, mostly work in work hours.
    static func pose(at date: Date = .now) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 0..<7: return "sleep"
        case 7..<9, 12..<13, 18..<20: return Bool.random() ? "meal" : ["code", "music"].randomElement()!
        case 9..<18: return ["code", "code", "music", "stretch", "tv"].randomElement()!
        default: return ["tv", "music", "stretch", "sleep"].randomElement()!
        }
    }

    /// Called from the background refresh too: each wake, a new pose.
    func refreshPose() {
        adoptExistingActivities()
        guard let activity, !activity.content.state.isRecording,
              activity.content.state.detail == nil else { return }
        send(resting())
    }

    private func startPoseLoop() {
        guard poseTask == nil else { return }
        poseTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                self?.refreshPose()
            }
        }
    }

    /// The source of truth for "recording": the coordinator, not the island.
    private var isActuallyRecording: Bool { AppServices.shared.coordinator.phase == .recording }

    /// Ambient presence — call whenever the app becomes active. Re-ups the
    /// stale date; if a recording is live it leaves that state alone.
    /// Adopts any activity that survived an app restart and ends extras, so
    /// relaunching never stacks multiple ARCAs in the island.
    func startCompanion() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        adoptExistingActivities()
        startPoseLoop()
        let state = resting()
        if let activity {
            // A recording state left behind (app killed mid-recording, an
            // update that landed late) is corrected here on every foreground.
            if activity.content.state.isRecording && isActuallyRecording { return }
            send(state)
            return
        }
        activity = try? Activity.request(
            attributes: RecordingActivityAttributes(title: "ARCA"),
            content: .init(state: state, staleDate: Self.staleDate)
        )
    }

    /// After an app restart `self.activity` is nil but the system may still
    /// show activities from the previous run — reclaim one, retire the rest.
    private func adoptExistingActivities() {
        guard activity == nil else { return }
        let existing = Activity<RecordingActivityAttributes>.activities
        guard !existing.isEmpty else { return }
        // Prefer a live recording; otherwise keep the newest companion.
        let keeper = existing.first { $0.content.state.isRecording } ?? existing[0]
        activity = keeper
        for extra in existing where extra.id != keeper.id {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func start(title: String, startedAt: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = RecordingActivityAttributes.ContentState(
            mode: "recording", startedAt: startedAt)
        if activity != nil {
            send(state)
        } else {
            activity = try? Activity.request(
                attributes: RecordingActivityAttributes(title: title),
                content: .init(state: state, staleDate: Self.staleDate)
            )
        }
    }

    func update(startedAt: Date, segmentCount: Int, isPaused: Bool = false) {
        let state = RecordingActivityAttributes.ContentState(
            mode: "recording", startedAt: startedAt, isPaused: isPaused,
            segmentCount: segmentCount)
        guard isActuallyRecording else { return }
        send(state)
    }

    /// A transient life sign in the island while ARCA works ("Reading your
    /// screenshot…", "3 actions ready") — reverts to the resting companion
    /// line after `seconds`. No-op during a recording.
    func note(_ text: String, for seconds: TimeInterval = 10) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        adoptExistingActivities()
        if activity == nil { startCompanion() }
        guard let activity, !activity.content.state.isRecording else { return }
        noteTask?.cancel()
        send(resting(detail: String(text.prefix(80))))
        noteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled,
                  let activity = self?.activity,
                  !activity.content.state.isRecording else { return }
            if let state = self?.resting() { self?.send(state) }
        }
    }

    /// Recording finished — ARCA stays, back in companion mode.
    func end() {
        adoptExistingActivities()
        send(resting())
    }

    /// Fully dismiss (rarely needed — e.g. user turned the companion off).
    func endAll() {
        Task { @MainActor in
            await self.activity?.end(nil, dismissalPolicy: .immediate)
            self.activity = nil
        }
    }

    /// Live Activities cap out around 8h; re-upped on every foreground.
    private static var staleDate: Date { .now.addingTimeInterval(8 * 3600) }
}
#endif
