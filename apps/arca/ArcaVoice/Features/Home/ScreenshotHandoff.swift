#if os(iOS)
import Foundation
import ArcaVoiceKit

/// Publishes a Handoff-eligible `NSUserActivity` right after a screenshot is
/// read on the phone, so ARCA's icon shows up in the Mac's Handoff spot (Dock
/// corner / Lock Screen) without the user re-opening the app there. Tapping it
/// on the Mac continues straight into the summary + "create the schedule
/// now?" review — see `RootView`'s `onContinueUserActivity` (macOS) and
/// `NotchAgent.presentHandoffReview`.
///
/// Only an id crosses in the activity payload (`NSUserActivity.userInfo` is
/// not meant for real payloads and Handoff's own transfer is small/best-effort
/// anyway). The actual title/summary/action-items already live in the
/// `RecordingSession` this device just saved, and RelaySync carries that the
/// rest of the way once the Mac asks for it.
@MainActor
final class ScreenshotHandoff {
    static let shared = ScreenshotHandoff()

    private var activity: NSUserActivity?
    private var expireTask: Task<Void, Never>?

    private init() {}

    func publish(sessionUID: String, title: String, hasSchedule: Bool) {
        expireTask?.cancel()

        let next = NSUserActivity(activityType: ArcaHandoff.screenshotReviewActivityType)
        next.title = title
        next.userInfo = [
            ArcaHandoff.sessionUIDKey: sessionUID,
            ArcaHandoff.hasScheduleKey: hasSchedule,
        ]
        next.isEligibleForHandoff = true
        // Stale by design: nobody wants a 10-minute-old screenshot still
        // dangling as a Handoff option in the evening.
        next.becomeCurrent()

        activity?.resignCurrent()
        activity?.invalidate()
        activity = next

        expireTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled else { return }
            self?.clear()
        }
    }

    func clear() {
        expireTask?.cancel()
        expireTask = nil
        activity?.resignCurrent()
        activity?.invalidate()
        activity = nil
    }
}
#endif
