import SwiftUI

@main
struct ArcaVoiceWatchApp: App {
    init() {
        WatchSync.shared.activate()
        WatchSync.shared.loadLatestVitals()
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                TabView {
                    FaceRecordView()
                    DeepMeasureView()
                    SummaryListView()
                }
                .tabViewStyle(.verticalPage)
            }
        }
    }
}
