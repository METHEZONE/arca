import SwiftUI
import SwiftData
import ArcaVoiceKit

@main
struct ArcaVoiceApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for:
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
        } catch {
            fatalError("SwiftData container creation failed: \(error)")
        }

        // Personal build: keys ship in the bundle so every device just works.
        ArcaConfig.importBundledKeysIfNeeded()
        #if os(macOS)
        // The ~/.arca staging file still wins on the Mac (rotate keys there).
        ArcaConfig.importVoiceKeysIntoKeychainIfNeeded()
        #endif
        #if os(iOS)
        PhoneWatchSync.shared.configure(container: container)
        #endif
        AppServices.shared.configure(container: container)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}
