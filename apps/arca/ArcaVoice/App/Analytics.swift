import Foundation
import ArcaVoiceKit
#if canImport(PostHog)
import PostHog
#endif

/// Product analytics (PostHog, project "ARCA", US cloud).
///
/// What leaves the device: which screen, which button, the funnel events
/// `BrainClient.track` already emits, crashes, and — on iPhone — a session
/// replay with every text field, image, and anything marked `.analyticsPrivate()`
/// (meeting notes, transcripts, chat, results) masked. Never meeting content.
enum Analytics {
    /// Write-only client key; safe to ship in the app.
    private static let projectToken = "phc_AeRzY5T5CapK2gokSFNsFHpcXitYcCjjMfGiJwNGS7W5"

    @MainActor static func start() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-noAnalytics") { return }
        #endif
        #if canImport(PostHog)
        let config = PostHogConfig(projectToken: projectToken, host: "https://us.i.posthog.com")
        config.captureApplicationLifecycleEvents = true
        config.captureScreenViews = true
        config.errorTrackingConfig.autoCapture = true
        #if os(iOS)
        // ARCA sends its own local notifications; PostHog push isn't used and
        // mustn't swizzle the notification delegate.
        config.capturePushNotificationSubscriptions = false
        config.capturePushNotificationOpened = false
        config.captureElementInteractions = true
        config.captureSwiftUIElementInteractions = true
        config.sessionReplay = true
        config.sessionReplayConfig.maskAllTextInputs = true
        config.sessionReplayConfig.maskAllImages = true
        // SwiftUI screens only replay as screenshots; the wireframe mode came
        // back blank. Masks (.analyticsPrivate, inputs, images) still apply.
        config.sessionReplayConfig.screenshotMode = true
        #endif
        PostHogSDK.shared.setup(config)
        #if DEBUG
        PostHogSDK.shared.register(["build": "debug", "edition": ArcaEdition.isBeta ? "beta" : "main"])
        #else
        PostHogSDK.shared.register(["build": "release", "edition": ArcaEdition.isBeta ? "beta" : "main"])
        #endif
        // Every funnel event the app already sends to ARCA Brain goes here too.
        BrainClient.onTrack = { kind in PostHogSDK.shared.capture(kind) }
        identify()
        #endif
    }

    /// The device id — the same one inside the free-tier grant
    /// (`dev-<id>@arca.device`), so PostHog people join ARCA Cloud's rows.
    @MainActor static func identify() {
        #if canImport(PostHog)
        var props: [String: Any] = ["free_tier": ArcaCloud.isFreeTier]
        if let email = AccountDefaults.string("cloudAccountEmail") { props["email"] = email }
        if let name = UserDefaults.standard.string(forKey: "ownerName"), !name.isEmpty { props["name"] = name }
        PostHogSDK.shared.identify(ArcaCloud.deviceId, userProperties: props)
        #endif
    }

    /// Closed beta (friends, told at onboarding): the words themselves, so we
    /// can read what people actually ask ARCA and fix what it gets wrong.
    /// `shareConversations = false` in defaults turns it off. Content events skip `.analyticsPrivate` replay
    /// masking by design — they're text, sent on purpose.
    static var sharesConversations: Bool {
        UserDefaults.standard.object(forKey: "shareConversations") as? Bool ?? true
    }

    static func content(_ event: String, _ properties: [String: Any], limit: Int = 6000) {
        #if canImport(PostHog)
        guard sharesConversations else { return }
        let clipped = properties.mapValues { value -> Any in
            (value as? String).map { String($0.prefix(limit)) } ?? value
        }
        PostHogSDK.shared.capture(event, properties: clipped)
        #endif
    }

    /// One event per proposal state change ("shown", "approved", "rejected",
    /// "auto_executed"), keyed by `id`, so shown→answered latency and "shown, never
    /// answered" come out of a single PostHog query. `age_s` = seconds since the
    /// item was created. The bare funnel kinds in `BrainClient.track` carry no
    /// payload; this is the payload.
    static func proposal(_ phase: String, id: UUID, kind: String, title: String, source: String, since: Date) {
        content("proposal_event", [
            "phase": phase, "id": id.uuidString, "kind": kind, "title": title,
            "source": source, "age_s": Int(Date.now.timeIntervalSince(since)),
        ], limit: 200)
    }

    /// Google sign-in: the same person, now with a name on the dashboard.
    @MainActor static func signedIn(email: String) {
        #if canImport(PostHog)
        PostHogSDK.shared.alias(email)
        identify()
        #endif
    }
}

import SwiftUI

extension View {
    /// Hides this view's content from session replay — anything with the
    /// user's words in it.
    @ViewBuilder func analyticsPrivate() -> some View {
        #if canImport(PostHog) && os(iOS)
        self.postHogMask()
        #else
        self
        #endif
    }

    /// Names the screen for PostHog (SwiftUI screens aren't auto-named).
    @ViewBuilder func analyticsScreen(_ name: String) -> some View {
        #if canImport(PostHog)
        self.postHogScreenView(name)
        #else
        self
        #endif
    }
}
