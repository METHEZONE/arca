import SwiftUI
import SwiftData
import ArcaVoiceKit
#if os(iOS)
import UIKit
#endif

@main
struct ArcaVoiceApp: App {
    let container: ModelContainer
    @State private var language = ArcaLanguage.shared
    #if os(iOS)
    @UIApplicationDelegateAdaptor(ArcaAppDelegate.self) private var appDelegate
    #endif

    init() {
        do {
            container = try Self.makeContainer()
        } catch {
            NSLog("[ArcaVoice] persistent store failed, falling back to in-memory store: %@", "\(error)")
            AppServices.shared.startupNotice = "ARCA could not open its saved data, so this launch is using a temporary library. Restart the app; if it repeats, export your data and reset the store."
            do {
                let schema = Schema([
                    RecordingSession.self,
                    AudioAsset.self,
                    StoredSegment.self,
                    SpeakerRecord.self,
                    SessionNote.self,
                    TodoTask.self,
                    ChatLogEntry.self,
                    MemoryFact.self,
                    ReplyProposal.self,
                    ActionProposal.self,
                ])
                container = try ModelContainer(
                    for: schema,
                    configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                )
            } catch {
                preconditionFailure("SwiftData in-memory fallback failed: \(error)")
            }
        }

        // Personal build: keys ship in the bundle so every device just works.
        ArcaConfig.importBundledKeysIfNeeded()
        // Subscribe before anything else can crash. Diagnostics from the
        // previous run arrive shortly after this — MetricKit never reports at
        // crash time, only on a later launch.
        CrashDiagnosticsReporter.start()
        CaptureTrace.sink = { DebugTrace.log("capture: \($0)") }
        #if os(macOS)
        // The ~/.arca staging file still wins on the Mac (rotate keys there).
        ArcaConfig.importVoiceKeysIntoKeychainIfNeeded()
        #endif
        #if os(iOS)
        PhoneWatchSync.shared.configure(container: container)
        BackgroundRefresh.register()
        #endif
        AppServices.shared.configure(container: container)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // Copy is resolved at render time, so switching language has to
                // rebuild the tree. Keyed on a counter that only changes when the
                // user actually picks a different language — never on launch.
                .id(language.generation)
                .tint(ArcaFace.ember)
        }
        .modelContainer(container)

        #if os(macOS)
        // The chat in its own window — opened from the floating ARCA.
        Window(L("ARCA 채팅", "ARCA Chat"), id: "arca-chat") {
            ChatWindowView()
                .id(language.generation)
        }
        .modelContainer(container)
        .defaultSize(width: 520, height: 680)
        .keyboardShortcut("j", modifiers: [.command, .shift])
        #endif
    }

    private static func makeContainer() throws -> ModelContainer {
        let accountId = AccountStore.currentAccountId()
        if AccountStore.isDefault(accountId) {
            #if ARCA_TEST_BUILD || ARCA_BETA
            // 테스트/베타 앱은 본편의 default.store를 절대 공유하지 않는다 —
            // 자기만의 스토어 파일에 격리.
            let schema = Schema([
                RecordingSession.self,
                AudioAsset.self,
                StoredSegment.self,
                SpeakerRecord.self,
                SessionNote.self,
                TodoTask.self,
                ChatLogEntry.self,
                MemoryFact.self,
                ReplyProposal.self,
                    ActionProposal.self,
            ])
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let url = base
                .appendingPathComponent(ArcaEdition.dataFolderName, isDirectory: true)
                .appendingPathComponent(ArcaEdition.isBeta ? "arca-beta.store" : "arca-test.store")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, url: url)
            )
            #else
            return try ModelContainer(for:
                RecordingSession.self,
                AudioAsset.self,
                StoredSegment.self,
                SpeakerRecord.self,
                SessionNote.self,
                TodoTask.self,
                ChatLogEntry.self,
                MemoryFact.self,
                ReplyProposal.self,
                ActionProposal.self
            )
            #endif
        }

        let schema = Schema([
            RecordingSession.self,
            AudioAsset.self,
            StoredSegment.self,
            SpeakerRecord.self,
            SessionNote.self,
            TodoTask.self,
            ChatLogEntry.self,
            MemoryFact.self,
            ReplyProposal.self,
                    ActionProposal.self,
        ])
        let url = accountStoreURL(accountId: accountId)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, url: url)
        )
    }

    private static func accountStoreURL(accountId: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("ArcaVoice", isDirectory: true)
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(accountId, isDirectory: true)
            .appendingPathComponent("arca.store")
    }
}

#if os(iOS)
/// Exists for exactly one reason SwiftUI cannot express: a background
/// `URLSession` reports completions it finished while the app was suspended (or
/// after iOS relaunched the app to deliver them) through a UIApplicationDelegate
/// callback. Without this, transcription uploads that finished in the background
/// would never be acknowledged and iOS would stop granting the app background
/// time for them.
final class ArcaAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundUploader.sessionIdentifier else {
            completionHandler()
            return
        }
        // Recreating the session with the same identifier is what lets iOS hand
        // its finished tasks over.
        BackgroundUploader.prepareForBackgroundLaunch()
        // UIKit hands this over as a plain closure; the uploader calls it back on
        // the main queue, which is where UIKit requires it.
        nonisolated(unsafe) let completion = completionHandler
        BackgroundUploader.shared.setLaunchCompletionHandler { completion() }
        // A launch triggered this way is the natural moment to finish anything
        // that was interrupted: the pass whose upload just landed is stranded in
        // `.processing`, and the audio is still on disk.
        Task { @MainActor in
            AppServices.shared.recoverOrphanedRecordings()
            AppServices.shared.retryFailedFinalPasses()
        }
    }
}
#endif
