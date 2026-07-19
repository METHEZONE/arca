import SwiftUI
import SwiftData
import ArcaVoiceKit

@main
struct ArcaVoiceApp: App {
    let container: ModelContainer

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
        }
        .modelContainer(container)
    }

    private static func makeContainer() throws -> ModelContainer {
        let accountId = AccountStore.currentAccountId()
        if AccountStore.isDefault(accountId) {
            #if ARCA_TEST_BUILD
            // 테스트 앱은 본편의 default.store를 절대 공유하지 않는다 —
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
            ])
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let url = base
                .appendingPathComponent("ArcaVoiceTest", isDirectory: true)
                .appendingPathComponent("arca-test.store")
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
                ReplyProposal.self
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
