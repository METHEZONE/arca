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

    /// Ambient presence — call whenever the app becomes active. Re-ups the
    /// stale date; if a recording is live it leaves that state alone.
    /// Adopts any activity that survived an app restart and ends extras, so
    /// relaunching never stacks multiple ARCAs in the island.
    func startCompanion() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        adoptExistingActivities()
        let state = RecordingActivityAttributes.ContentState(
            mode: "companion", startedAt: .now)
        if let activity {
            if activity.content.state.isRecording { return }
            Task { @MainActor in
                await activity.update(ActivityContent(state: state, staleDate: Self.staleDate))
            }
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
        if let activity {
            Task { @MainActor in
                await activity.update(ActivityContent(state: state, staleDate: Self.staleDate))
            }
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
        Task { @MainActor in
            await self.activity?.update(ActivityContent(state: state, staleDate: Self.staleDate))
        }
    }

    /// Recording finished — ARCA stays, back in companion mode.
    func end() {
        let state = RecordingActivityAttributes.ContentState(
            mode: "companion", startedAt: .now)
        Task { @MainActor in
            await self.activity?.update(ActivityContent(state: state, staleDate: Self.staleDate))
        }
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
