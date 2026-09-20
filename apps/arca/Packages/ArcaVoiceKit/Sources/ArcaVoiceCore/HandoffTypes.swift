import Foundation

/// Handoff between a screenshot read on the phone and its review on the Mac.
///
/// The phone reads the screenshot, saves the plan locally, and publishes an
/// `NSUserActivity` of this type — that's what makes ARCA's icon show up in
/// the Mac's Handoff spot (Dock corner / Lock Screen) the moment the capture
/// is ready. Continuing it there hands the Mac just enough to find the same
/// session once RelaySync brings it across: no image bytes cross in the
/// activity payload, only a stable id.
public enum ArcaHandoff {
    /// Must also be listed in `NSUserActivityTypes` (Info.plist) on both
    /// platforms — same target/bundle id for iOS and macOS, so one entry in
    /// project.yml covers both.
    public static let screenshotReviewActivityType = "com.thezone.arca.voice.screenshot-review"

    /// `RecordingSession.directoryName` — the same id `SessionWire` relays
    /// across devices, so the continuing device can look the session up once
    /// it lands locally.
    public static let sessionUIDKey = "sessionUID"
    /// Whether the plan already has at least one dated action item, so the
    /// Mac can decide whether to show the "create the schedule now?" button
    /// without waiting on the full session to sync first.
    public static let hasScheduleKey = "hasSchedule"
}
