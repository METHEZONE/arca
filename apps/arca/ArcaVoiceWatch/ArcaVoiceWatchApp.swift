import SwiftUI

@main
struct ArcaVoiceWatchApp: App {
    init() {
        WatchSync.shared.activate()
        WatchSync.shared.loadLatestVitals()
    }

    /// Launch with `-ArcaStartPage 2` to open on a specific page (simulator screenshots).
    @State private var page = UserDefaults.standard.integer(forKey: "ArcaStartPage")

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                TabView(selection: $page) {
                    FaceRecordView().tag(0)
                    TodoListView().tag(1)
                    SummaryListView().tag(2)
                    DeepMeasureView().tag(3)
                }
                .tabViewStyle(.verticalPage)
            }
        }
    }
}
