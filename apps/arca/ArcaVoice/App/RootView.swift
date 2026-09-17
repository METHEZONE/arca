import SwiftUI
import SwiftData
import ArcaVoiceKit

struct RootView: View {
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
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
            Tab(value: AppTab.home) {
                HomeView()
            } label: {
                Label(L("홈", "Home"), systemImage: "sparkles")
            }
            Tab(value: AppTab.chat) {
                ChatTabView()
            } label: {
                Label(L("채팅", "Chat"), systemImage: "bubble.left.and.text.bubble.right")
            }
            Tab(value: AppTab.tasks) {
                TaskListView()
            } label: {
                Label(L("할 일", "Tasks"), systemImage: "checklist")
            }
            Tab(value: AppTab.brain) {
                NavigationStack {
                    BrainView()
                        .navigationTitle(L("메모리", "Memory"))
                        .navigationBarTitleDisplayMode(.inline)
                }
            } label: {
                Label(L("메모리", "Brain"), systemImage: "brain.head.profile")
            }
            Tab(value: AppTab.library) {
                library
            } label: {
                Label(L("라이브러리", "Library"), systemImage: "waveform")
            }
        }
        // ARCA is a night creature: the home is painted dark, so every other
        // tab follows or the app looks like two apps. One accent everywhere.
        .preferredColorScheme(.dark)
        .tint(ArcaFace.ember)
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
            #if os(iOS)
            if phase == .background {
                BackgroundRefresh.flushOnBackground()
                BackgroundRefresh.schedule()
            }
            #endif
        }
        // Shared capture → straight into the context flow, kip!-style.
        .sheet(item: $contextItem) { item in
            ContextView(item: item) { chatItem in
                contextItem = nil
                // Hand the whole thread to the chat tab — image, analysis,
                // results — so "Open full chat" continues, not restarts.
                var payload: [String: Any] = [
                    "conversationId": "share-\(chatItem.id.uuidString)",
                ]
                if let text = chatItem.text { payload["text"] = text }
                if chatItem.kind == .image, let url = SharedInbox.imageURL(for: chatItem),
                   let data = try? Data(contentsOf: url) {
                    payload["imageData"] = data
                }
                SharedInbox.remove(chatItem)
                selectedTab = .chat
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    NotificationCenter.default.post(name: .arcaChatWithShare, object: nil,
                                                    userInfo: payload)
                }
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
            case "context":
                // The share extension just deep-linked us open — present the
                // shared item's action sheet immediately.
                presentPendingContextIfNeeded()
            case "linked":
                // Web onboarding finished and sent us back. Re-ask the backend
                // who this device belongs to now, so 설정 shows 연결됨 without
                // the user having to go looking for it.
                NotificationCenter.default.post(name: .arcaCloudLinked, object: nil)
            default:
                break
            }
        }
        #else
        MacOnboardingGate { CompanionHomeView() }
            .onReceive(NotificationCenter.default.publisher(for: .arcaOpenChatWindow)) { _ in
                openWindow(id: "arca-chat")
                NSApp.activate(ignoringOtherApps: true)
            }
            // arca://record|stop (arca-test:// on the test app) — lets
            // Shortcuts/Raycast and the ARCA Test verification harness drive
            // the core loop without touching the UI.
            .onOpenURL { url in
                switch url.host ?? url.lastPathComponent {
                case "record":
                    if coordinator.phase == .idle { services.startRecording() }
                case "stop":
                    services.stopRecording()
                case "linked":
                    // Web onboarding finished and sent us back — see the iOS
                    // branch above.
                    NotificationCenter.default.post(name: .arcaCloudLinked, object: nil)
                case "browse":
                    // arca://browse?task=... — open ARCA's browser and, with a
                    // task, hand it to the browser agent (Shortcuts/Raycast/harness).
                    BrowserAgentWindow.present()
                    let task = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first { $0.name == "task" }?.value ?? ""
                    if !task.isEmpty {
                        Task { for await _ in BrowserAgent.shared.run(task: task) {} }
                    }
                default:
                    break
                }
            }
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
                .navigationTitle(L("라이브러리", "Library"))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem {
                        Button {
                            showSettings = true
                        } label: {
                            Label(L("설정", "Settings"), systemImage: "gearshape")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            selectedSession = nil
                            showRecorder = true
                        } label: {
                            Label(L("새 녹음", "New Recording"), systemImage: "mic.badge.plus")
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
                    L("녹음을 고르거나 새로 시작하세요", "Select a recording or start a new one"),
                    systemImage: "waveform.badge.mic",
                    description: Text(L("⌘N을 누르면 바로 녹음이 시작돼요.", "Press ⌘N to start recording right away."))
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
        case .image: return L("공유한 이미지를 읽어 액션 플랜으로 만들까요?", "Read the shared image and turn it into an action plan?")
        case .url: return L("공유한 링크를 액션 플랜으로 정리할까요?", "Organize the shared link into an action plan?")
        case .text: return L("공유한 내용을 액션 플랜으로 만들까요?", "Turn the shared content into an action plan?")
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
                Button(L("나중에", "Later"), action: onDismiss)
                    .buttonStyle(.bordered)
                Button(L("만들기", "Create it"), action: onGenerate)
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
