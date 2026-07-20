#if os(iOS)
import AppIntents
import Foundation

extension Notification.Name {
    /// Chat tab listens: drop into a live voice turn.
    static let arcaOpenTalk = Notification.Name("arca.openTalk")
    /// Chat tab listens: continue a shared item's conversation in full chat.
    /// userInfo: conversationId (String), text (String?), imageData (Data?).
    static let arcaChatWithShare = Notification.Name("arca.chatWithShare")
}

/// "Talk to ARCA" — wire it to the Action Button or Back Tap via Shortcuts.
struct TalkToARCAIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to ARCA"
    static let description = IntentDescription("Start a voice conversation with ARCA.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppServices.shared.pendingRoute = "talk"
        return .result()
    }
}

/// "Record with ARCA" — one press starts a transcribed session.
struct RecordWithARCAIntent: AppIntent {
    static let title: LocalizedStringResource = "Record with ARCA"
    static let description = IntentDescription("Start an ARCA recording session.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppServices.shared.pendingRoute = "record"
        return .result()
    }
}

struct ArcaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TalkToARCAIntent(),
            phrases: ["Talk to \(.applicationName)"],
            shortTitle: "Talk",
            systemImageName: "waveform.and.mic")
        AppShortcut(
            intent: RecordWithARCAIntent(),
            phrases: ["Record with \(.applicationName)"],
            shortTitle: "Record",
            systemImageName: "mic.fill")
    }
}
#endif
