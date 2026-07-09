import SwiftUI
import SwiftData
import ArcaVoiceKit

struct RootView: View {
    @State private var services = AppServices.shared
    @State private var selectedSession: RecordingSession?
    @State private var showSettings = false
    @State private var showRecorder = false
    #if os(iOS)
    @State private var selectedTab: AppTab = .home
    @State private var contextItem: SharedInbox.Item?
    #endif
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @State private var inbox = SharedInboxProcessor()
    #endif

    private var coordinator: RecordingCoordinator { services.coordinator }

    var body: some View {
        #if os(iOS)
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "sparkles", value: AppTab.home) {
                HomeView()
            }
            Tab("Chat", systemImage: "bubble.left.and.text.bubble.right", value: AppTab.chat) {
                ChatTabView()
            }
            Tab("Tasks", systemImage: "checklist", value: AppTab.tasks) {
                TaskListView()
            }
            Tab("Brain", systemImage: "brain.head.profile", value: AppTab.brain) {
                NavigationStack { BrainView() }
            }
            Tab("Library", systemImage: "waveform", value: AppTab.library) {
                library
            }
        }
        .task {
            presentPendingContextIfNeeded()
            await RelaySync.shared.syncNow()
            await AmbientOps.shared.harvest(context: modelContext)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                presentPendingContextIfNeeded()
                Task {
                    await RelaySync.shared.syncNow()
                    await AmbientOps.shared.harvest(context: modelContext)
                }
            }
        }
        // Shared capture → straight into the context flow, kip!-style.
        .sheet(item: $contextItem) { item in
            ContextView(item: item) { chatItem in
                contextItem = nil
                SharedInbox.remove(chatItem)
                selectedTab = .chat
            } onDone: {
                if let item = contextItem { SharedInbox.remove(item) }
                contextItem = nil
            }
        }
        .onOpenURL { url in
            services.pendingRoute = url.host ?? url.lastPathComponent
        }
        .onChange(of: services.pendingRoute) { _, route in
            guard let route else { return }
            services.pendingRoute = nil
            switch route {
            case "talk":
                selectedTab = .chat
                // Let the tab mount before dropping into the voice turn.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    NotificationCenter.default.post(name: .arcaOpenTalk, object: nil)
                }
            case "record":
                selectedTab = .home
                if coordinator.phase == .idle { services.startRecording() }
            case "chat":
                selectedTab = .chat
            default:
                break
            }
        }
        #else
        CompanionHomeView()
        #endif
    }

    #if os(iOS)
    enum AppTab: Hashable { case home, chat, tasks, brain, library }

    /// The share extension raises a flag in the App Group; the next activation
    /// jumps straight into the context flow for the newest shared item.
    private func presentPendingContextIfNeeded() {
        let group = UserDefaults(suiteName: SharedInbox.appGroupID)
        guard group?.bool(forKey: "pendingContext") == true,
              let latest = SharedInbox.pending().last else { return }
        group?.set(false, forKey: "pendingContext")
        contextItem = latest
    }
    #endif

    private var library: some View {
        NavigationSplitView {
            SessionListView(selection: $selectedSession)
                .navigationTitle("ARCA")
                .toolbar {
                    ToolbarItem {
                        Button {
                            showSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            selectedSession = nil
                            showRecorder = true
                        } label: {
                            Label("New Recording", systemImage: "mic.badge.plus")
                        }
                        .keyboardShortcut("n", modifiers: .command)
                    }
                }
        } detail: {
            if showRecorder || coordinator.phase != .idle {
                RecordView { saved in
                    showRecorder = false
                    selectedSession = saved
                }
            } else if let selectedSession {
                SessionDetailView(session: selectedSession)
            } else {
                ContentUnavailableView(
                    "Select a recording or start a new one",
                    systemImage: "waveform.badge.mic",
                    description: Text("Press ⌘N to start recording right away.")
                )
            }
        }
        .environment(coordinator)
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
            }
        }
        .onChange(of: services.sessionToOpen) { _, session in
            // Ambient surfaces (notch/island) ask us to show a session.
            if let session {
                showRecorder = false
                selectedSession = session
                services.sessionToOpen = nil
            }
        }
        #if os(iOS)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { inbox.refresh() }
        }
        .task { inbox.refresh() }
        .safeAreaInset(edge: .bottom) {
            if let item = inbox.offering {
                SharedOfferBanner(
                    item: item,
                    isWorking: inbox.isWorking,
                    onGenerate: {
                        Task {
                            if let saved = await inbox.generate(modelContext: modelContext) {
                                selectedSession = saved
                            }
                        }
                    },
                    onDismiss: { inbox.dismissCurrent() }
                )
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
        #endif
    }
}

#if os(iOS)
private struct SharedOfferBanner: View {
    let item: SharedInbox.Item
    let isWorking: Bool
    let onGenerate: () -> Void
    let onDismiss: () -> Void

    private var label: String {
        switch item.kind {
        case .image: return "Read the shared image and turn it into an action plan?"
        case .url: return "Organize the shared link into an action plan?"
        case .text: return "Turn the shared content into an action plan?"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(.green)
            Text(label)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            Spacer()
            if isWorking {
                ProgressView()
            } else {
                Button("Later", action: onDismiss)
                    .buttonStyle(.bordered)
                Button("Create it", action: onGenerate)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 10, y: 3)
    }
}
#endif

#Preview {
    RootView()
        .modelContainer(for: RecordingSession.self, inMemory: true)
}
