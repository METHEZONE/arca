#if os(macOS)
import AppKit
import ArcaVoiceKit

/// Watches Core Audio for another app starting to capture the microphone —
/// the moment a video call begins — and raises a "start transcribing?" prompt.
@MainActor
@Observable
final class MeetingDetector {
    struct DetectedMeeting: Equatable {
        let label: String
        let meetingApp: String?
    }

    private(set) var pending: DetectedMeeting?
    /// Fired on the rising edge of a detected meeting (notch agent hooks this).
    var onDetect: ((DetectedMeeting) -> Void)?
    private var knownPIDs: Set<pid_t> = []
    private var snoozedUntil = Date.distantPast
    private var pollTask: Task<Void, Never>?

    /// Meeting-capable apps we prompt for, matched by bundle-id PREFIX because
    /// browsers and Electron apps capture the mic from helper processes
    /// (Chrome → com.google.Chrome.helper, Safari → com.apple.WebKit.GPU, …).
    private static let meetingApps: [(prefix: String, label: String)] = [
        ("us.zoom", "Zoom"),
        ("app.zoom", "Zoom"),
        ("com.microsoft.teams", "Teams"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.tinyspeck.slackmacgap", "Slack Huddle"),
        ("com.hnc.Discord", "Discord"),
        ("com.google.Chrome", "Chrome meeting (Meet)"),
        ("com.apple.WebKit", "Safari meeting"),
        ("com.apple.Safari", "Safari meeting"),
        ("company.thebrowser", "Arc meeting (Meet)"),
        ("com.brave.Browser", "Brave meeting"),
        ("org.mozilla", "Firefox meeting"),
        ("com.microsoft.edgemac", "Edge meeting"),
    ]

    private static let storableMeetingApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Teams",
        "com.microsoft.teams": "Teams",
        "com.hnc.Discord": "Discord",
        "com.tinyspeck.slackmacgap": "Slack",
    ]

    static func label(forBundleID bundleID: String) -> String? {
        meetingApps.first { bundleID.hasPrefix($0.prefix) }?.label
    }

    func start(isBusy: @escaping @MainActor () -> Bool) {
        guard pollTask == nil else { return }
        // Seed with the current state so already-running calls don't prompt at app launch.
        knownPIDs = Set(MicActivity.currentMicUsers().map(\.pid))
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                self?.scan(isBusy: isBusy)
            }
        }
    }

    private func scan(isBusy: @MainActor () -> Bool) {
        let users = MicActivity.currentMicUsers()
        let pids = Set(users.map(\.pid))
        defer { knownPIDs = pids }

        guard pending == nil, Date() >= snoozedUntil, !isBusy() else { return }

        for user in users where !knownPIDs.contains(user.pid) {
            guard let bundleID = user.bundleID else { continue }
            if let label = Self.label(forBundleID: bundleID) {
                let meeting = DetectedMeeting(label: label, meetingApp: Self.detectRunningMeetingApp())
                pending = meeting
                onDetect?(meeting)
                return
            }
        }
    }

    static func detectRunningMeetingApp() -> String? {
        let matches = NSWorkspace.shared.runningApplications.compactMap { app -> String? in
            guard let bundleID = app.bundleIdentifier else { return nil }
            return storableMeetingApps[bundleID]
        }
        let unique = Set(matches)
        return unique.count == 1 ? unique.first : nil
    }

    func accept() {
        pending = nil
        snoozedUntil = Date().addingTimeInterval(60)
    }

    func dismiss() {
        pending = nil
        snoozedUntil = Date().addingTimeInterval(10 * 60)
    }
}
#endif
