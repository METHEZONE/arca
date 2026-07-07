import SwiftUI

@main
struct ArcaVoiceWatchApp: App {
    init() {
        WatchSync.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            FaceRecordView()
        }
    }
}
