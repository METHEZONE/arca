#if os(macOS)
import SwiftUI
import SwiftData
import ArcaVoiceKit

enum CompanionHomeMode: String, CaseIterable, Identifiable {
    case home, memory, day, wiki, library
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "홈"
        case .memory: return "메모리"
        case .day: return "하루"
        case .wiki: return "위키"
        case .library: return "라이브러리"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "sparkles"
        case .memory: return "point.3.connected.trianglepath.dotted"
        case .day: return "sun.horizon"
        case .wiki: return "book.closed"
        case .library: return "waveform"
        }
    }
}

enum CompanionHomeViewModel {
    static func ownerDisplayName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "Me" else { return "민성님" }
        return trimmed.hasSuffix("님") ? trimmed : "\(trimmed)님"
    }

    static func greeting(ownerName: String, date: Date = .now) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        let timeWord: String
        switch hour {
        case 5..<11: timeWord = "좋은 아침이에요"
        case 11..<17: timeWord = "좋은 오후예요"
        case 17..<22: timeWord = "좋은 저녁이에요"
        default: timeWord = "고요한 밤이에요"
        }
        return "\(timeWord), \(ownerDisplayName(ownerName))"
    }

    static func earliestDate(sessions: [RecordingSession],
                             facts: [MemoryFact],
                             chatEntries: [ChatLogEntry]) -> Date? {
        (sessions.map(\.createdAt) + facts.map(\.createdAt) + chatEntries.map(\.createdAt)).min()
    }

    static func fallbackRemark(dayCount: Int, memoryCount: Int) -> String {
        let variants = [
            "우리가 함께한 지 D+\(dayCount)일째예요. 기억 \(memoryCount)개를 모았어요.",
            "D+\(dayCount), 당신의 조각 \(memoryCount)개를 품고 있어요.",
            "처음 만난 날부터 \(memoryCount)개의 기억이 쌓였어요.",
        ]
        return variants[abs(dayCount + memoryCount) % variants.count]
    }
}

struct CompanionHomeView: View {
    @State private var services = AppServices.shared
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecordingSession.createdAt, order: .reverse) private var sessions: [RecordingSession]
    @Query(sort: \MemoryFact.createdAt, order: .reverse) private var facts: [MemoryFact]
    @Query(sort: \ChatLogEntry.createdAt, order: .forward) private var chatLog: [ChatLogEntry]

    @State private var mode: CompanionHomeMode = .home
    @State private var activeConversationId: String?
    @State private var chat = ChatSession()
    @State private var selectedSession: RecordingSession?
    @State private var showRecorder = false
    @State private var showSettings = false
    @State private var showSkins = false
    @State private var showRightRail = true
    @State private var memorySearch = ""
    @State private var remark = MemoryRemarkProvider()
    @State private var projectDialogConversationId: String?
    @State private var newProjectName = ""

    private let background = Color(red: 0.03, green: 0.05, blue: 0.09)
    private var coordinator: RecordingCoordinator { services.coordinator }
    private var ownerName: String { CompanionHomeViewModel.ownerDisplayName(services.ownerName) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 240)
                .background(Color.black.opacity(0.20))
            Divider().overlay(.white.opacity(0.08))
            centerPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showRightRail {
                Divider().overlay(.white.opacity(0.08))
                CompanionTodoRail()
                    .frame(width: 300)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(background.ignoresSafeArea())
        .foregroundStyle(.white)
        .toolbar { toolbar }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
        }
        .sheet(isPresented: $showSkins) {
            SkinsView()
                .frame(minWidth: 520, minHeight: 520)
        }
        .alert("새 프로젝트", isPresented: Binding(
            get: { projectDialogConversationId != nil },
            set: { if !$0 { projectDialogConversationId = nil } }
        )) {
            TextField("프로젝트 이름", text: $newProjectName)
            Button("지정") {
                if let id = projectDialogConversationId {
                    assignProject(newProjectName, to: id)
                }
                projectDialogConversationId = nil
                newProjectName = ""
            }
            Button("취소", role: .cancel) {
                projectDialogConversationId = nil
                newProjectName = ""
            }
        }
        .onAppear {
            remark.load(ownerName: ownerName, facts: facts, sessions: sessions, chatEntries: chatLog)
        }
        .onChange(of: facts.count) {
            remark.load(ownerName: ownerName, facts: facts, sessions: sessions, chatEntries: chatLog)
        }
        .onChange(of: services.sessionToOpen) { _, session in
            guard let session else { return }
            showRecorder = false
            selectedSession = session
            mode = .library
            activeConversationId = nil
            services.sessionToOpen = nil
        }
        .environment(coordinator)
        .onDisappear { chat.endConversation() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Button {
                withAnimation(.spring(duration: 0.25)) { showRightRail.toggle() }
            } label: {
                Label("Right rail", systemImage: "sidebar.right")
            }
        }
        // 녹음은 핵심 기능 — 어떤 모드에서도 ⌘N 한 번에 시작된다.
        ToolbarItem(placement: .primaryAction) {
            Button {
                startNewRecording()
            } label: {
                Label("New Recording", systemImage: "mic.badge.plus")
            }
            .keyboardShortcut("n", modifiers: .command)
        }
    }

    /// 원탭 녹음: 누르는 즉시 녹음이 시작되고 라이브 전사 화면으로 간다.
    /// 중간 "Tap to start recording" 화면을 거치지 않는다.
    private func startNewRecording() {
        selectedSession = nil
        activeConversationId = nil
        showRecorder = true
        mode = .library
        if coordinator.phase == .idle {
            services.startRecording()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ArcaFace(mood: .idle, size: 24, halo: false, alive: false)
                    .frame(width: 28, height: 28)
                Text("ARCA")
                    .font(.system(.headline, design: .rounded, weight: .black))
                Spacer()
            }
            .padding(.top, 18)
            .padding(.horizontal, 16)

            VStack(spacing: 4) {
                ForEach(CompanionHomeMode.allCases) { item in
                    sidebarButton(mode: item)
                }
            }
            .padding(.horizontal, 10)

            HStack {
                Text("채팅")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button {
                    startEmptyChat()
                } label: {
                    Label("새 채팅", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(ArcaSkins.current.hi)
            }
            .padding(.horizontal, 16)

            chatList

            Spacer()

            Button {
                showSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .padding(16)
        }
    }

    private func sidebarButton(mode item: CompanionHomeMode) -> some View {
        Button {
            withAnimation(.spring(duration: 0.25)) {
                mode = item
                if item != .home { activeConversationId = nil }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .frame(width: 18)
                Text(item.title)
                Spacer()
            }
            .font(.system(.callout, design: .rounded, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(self.mode == item ? .white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(self.mode == item ? .white : .white.opacity(0.68))
        }
        .buttonStyle(.plain)
    }

    private var chatList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(projectGroups, id: \.name) { group in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(group.name)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.35))
                            .padding(.horizontal, 16)
                        ForEach(group.conversations) { conversation in
                            conversationButton(conversation)
                        }
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }

    private func conversationButton(_ conversation: ConversationSummary) -> some View {
        Button {
            openConversation(conversation.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(conversation.title)
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .lineLimit(1)
                Text("\(conversation.count)턴 · \(conversation.lastAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.38))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(activeConversationId == conversation.id ? .white.opacity(0.11) : .white.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Menu("프로젝트 지정") {
                ForEach(projectNames, id: \.self) { project in
                    Button(project) { assignProject(project, to: conversation.id) }
                }
                Divider()
                Button("새 프로젝트…") {
                    newProjectName = ""
                    projectDialogConversationId = conversation.id
                }
            }
            Button("삭제", role: .destructive) {
                deleteConversation(conversation.id)
            }
        }
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private var centerPane: some View {
        switch mode {
        case .home:
            if activeConversationId != nil {
                CompanionChatThread(chat: chat, onBack: endActiveConversation)
            } else {
                homeHero
            }
        case .memory:
            memoryPane
        case .day:
            DayLogView { session in
                selectedSession = session
                showRecorder = false
                mode = .library
            }
        case .wiki:
            UserWikiView(ownerName: ownerName, facts: facts, sessions: sessions)
        case .library:
            CompanionLibraryView(selectedSession: $selectedSession, showRecorder: $showRecorder)
        }
    }

    private var homeHero: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 24)
            // iOS 홈과 동일한 문법: ARCA를 누르면 바로 녹음.
            Button {
                if coordinator.phase == .idle {
                    startNewRecording()
                } else {
                    showRecorder = true
                    mode = .library
                }
            } label: {
                ArcaFace(mood: coordinator.phase == .idle ? .idle : .listening, size: 180, halo: true)
                    .frame(width: 210, height: 210)
            }
            .buttonStyle(.plain)
            .help("ARCA를 누르면 바로 녹음이 시작돼요")

            VStack(spacing: 8) {
                Text(CompanionHomeViewModel.greeting(ownerName: services.ownerName))
                    .font(.system(.title2, design: .rounded, weight: .bold))
                Text(remark.text.isEmpty ? "오늘도 당신의 기억을 지키고 있어요." : remark.text)
                    .font(.system(.headline, design: .rounded, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))

            recordCTA
            statsRow
            recentHighlights
            Spacer(minLength: 18)
            CompanionDraftComposer(placeholder: "ARCA에게 말 걸기…") { text in
                startNewConversation(text: text)
            }
            .padding(.horizontal, 34)
            .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    /// 홈 정중앙의 녹음 시작 버튼 — 핵심 기능은 첫 화면에서 한 번에.
    private var recordCTA: some View {
        Button {
            if coordinator.phase == .idle {
                startNewRecording()
            } else {
                showRecorder = true
                mode = .library
            }
        } label: {
            Label(coordinator.phase == .idle ? "녹음 시작" : "녹음 중 — 열기",
                  systemImage: coordinator.phase == .idle ? "mic.fill" : "waveform")
                .font(.system(.headline, design: .rounded, weight: .bold))
                .padding(.horizontal, 26)
                .padding(.vertical, 13)
                .background(
                    coordinator.phase == .idle ? ArcaTheme.recording : ArcaSkins.current.hi,
                    in: Capsule()
                )
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private var statsRow: some View {
        let earliest = CompanionHomeViewModel.earliestDate(sessions: sessions, facts: facts, chatEntries: chatLog)
        let dayCount = CompanionHomeLogic.dayCount(since: earliest)
        return HStack(spacing: 10) {
            statChip("함께한 지 D+\(dayCount)일", systemImage: "calendar.badge.clock")
            statChip("기억 \(facts.count)개", systemImage: "brain.head.profile")
            statChip("세션 \(sessions.count)개", systemImage: "waveform")
            Button {
                showSkins = true
            } label: {
                statChip("스킨", systemImage: "sparkles")
            }
            .buttonStyle(.plain)
        }
    }

    private func statChip(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(.caption, design: .rounded, weight: .bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white.opacity(0.08), in: Capsule())
            .foregroundStyle(.white.opacity(0.84))
    }

    private var recentHighlights: some View {
        HStack(spacing: 10) {
            ForEach(sessions.prefix(3)) { session in
                Button {
                    selectedSession = session
                    showRecorder = false
                    mode = .library
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(session.title)
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .lineLimit(1)
                        Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.44))
                    }
                    .frame(width: 170, alignment: .leading)
                    .padding(12)
                    .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var memoryPane: some View {
        VStack(spacing: 12) {
            TextField("기억 검색…", text: $memorySearch)
                .textFieldStyle(.plain)
                .font(.system(.callout, design: .rounded))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 20)
                .padding(.top, 18)
            BrainView(searchQuery: memorySearch)
        }
    }

    private var projectGroups: [(name: String, conversations: [ConversationSummary])] {
        let summaries = conversations
        let grouped = Dictionary(grouping: summaries) { $0.projectName ?? "일반" }
        return grouped.keys.sorted { lhs, rhs in
            if lhs == "일반" { return false }
            if rhs == "일반" { return true }
            return lhs.localizedCompare(rhs) == .orderedAscending
        }.map { key in
            (key, grouped[key]?.sorted { $0.lastAt > $1.lastAt } ?? [])
        }
    }

    private var conversations: [ConversationSummary] {
        Dictionary(grouping: chatLog) { $0.conversationId }.compactMap { id, entries in
            guard let last = entries.max(by: { $0.createdAt < $1.createdAt }) else { return nil }
            let firstUser = entries.first(where: { $0.roleRaw == "user" && !$0.text.isEmpty })?.text
            return ConversationSummary(
                id: id,
                title: CompanionHomeLogic.conversationTitle(firstUserText: firstUser, fallbackText: last.text, maxCharacters: 28),
                lastAt: last.createdAt,
                count: entries.count,
                projectName: entries.first(where: { $0.projectName?.isEmpty == false })?.projectName
            )
        }
        .sorted { $0.lastAt > $1.lastAt }
    }

    private var projectNames: [String] {
        let names = Set(chatLog.compactMap { entry -> String? in
            guard let project = entry.projectName?.trimmingCharacters(in: .whitespacesAndNewlines), !project.isEmpty else { return nil }
            return project
        })
        return names.sorted()
    }

    private func startEmptyChat() {
        chat.endConversation()
        chat = ChatSession()
        activeConversationId = chat.conversationId
        mode = .home
    }

    private func startNewConversation(text: String) {
        chat.endConversation()
        let next = ChatSession()
        chat = next
        activeConversationId = next.conversationId
        mode = .home
        next.draftText = text
        next.send()
    }

    private func openConversation(_ id: String) {
        chat.endConversation()
        let next = ChatSession(conversationId: id)
        next.restore(from: chatLog.filter { $0.conversationId == id })
        chat = next
        activeConversationId = id
        mode = .home
    }

    private func endActiveConversation() {
        chat.endConversation()
        activeConversationId = nil
        chat = ChatSession()
    }

    private func assignProject(_ name: String, to conversationId: String) {
        let project = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty else { return }
        for entry in chatLog where entry.conversationId == conversationId {
            entry.projectName = project
        }
        try? modelContext.save()
    }

    private func deleteConversation(_ conversationId: String) {
        for entry in chatLog where entry.conversationId == conversationId {
            modelContext.delete(entry)
        }
        try? modelContext.save()
        if activeConversationId == conversationId { endActiveConversation() }
    }
}

private struct ConversationSummary: Identifiable {
    let id: String
    let title: String
    let lastAt: Date
    let count: Int
    let projectName: String?
}

private struct CompanionChatThread: View {
    @Bindable var chat: ChatSession
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Label("홈으로", systemImage: "chevron.left")
                        .font(.system(.callout, design: .rounded, weight: .semibold))
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(chat.messages) { message in
                            CompanionBubble(message: message, isThinking: false)
                                .id(message.id)
                        }
                        if chat.isThinking {
                            HStack(spacing: 8) {
                                ArcaFace(mood: .thinking, size: 28, halo: false)
                                    .frame(width: 32, height: 32)
                                ProgressView()
                                    .controlSize(.small)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 28)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .onChange(of: chat.messages.last?.id) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
                }
            }

            CompanionChatInput(text: $chat.draftText, disabled: chat.isThinking) {
                chat.send()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
    }
}

private struct CompanionBubble: View {
    let message: ChatMessage
    let isThinking: Bool
    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 80) }
            if !isUser {
                ArcaFace(mood: isThinking ? .thinking : .idle, size: 28, halo: false, alive: false)
                    .frame(width: 32, height: 32)
            }
            Text(message.displayText)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(isUser ? .white : .white.opacity(0.88))
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(isUser ? ArcaTheme.idle.opacity(0.88) : .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            if !isUser { Spacer(minLength: 80) }
        }
        .padding(.horizontal, 28)
    }
}

private struct CompanionChatInput: View {
    @Binding var text: String
    var disabled: Bool
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TextField("메시지 입력…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .rounded))
                .lineLimit(1...4)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || disabled ? .white.opacity(0.25) : ArcaSkins.current.hi)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || disabled)
        }
    }

    private func send() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !disabled else { return }
        onSend()
    }
}

private struct CompanionDraftComposer: View {
    let placeholder: String
    let onSend: (String) -> Void
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 10) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .rounded))
                .lineLimit(1...4)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 18))
                .onSubmit(send)
            Button(action: send) {
                Label("Send", systemImage: "arrow.up.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .white.opacity(0.24) : ArcaSkins.current.hi)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        onSend(text)
    }
}

private struct CompanionLibraryView: View {
    @State private var services = AppServices.shared
    @Binding var selectedSession: RecordingSession?
    @Binding var showRecorder: Bool

    private var coordinator: RecordingCoordinator { services.coordinator }

    var body: some View {
        // 다크 3분할 안에 NavigationSplitView를 중첩하면 사이드바가 겹쳐
        // 깨져 보인다 — 평평한 2컬럼으로 렌더링한다.
        HStack(spacing: 0) {
            SessionListView(selection: $selectedSession)
                .scrollContentBackground(.hidden)
                .frame(width: 300)
            Divider()
            Group {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 세션을 클릭하면 녹음 대기 화면이 아니라 그 세션의 전사가 보여야 한다.
        .onChange(of: selectedSession) { _, newValue in
            if newValue != nil, coordinator.phase == .idle {
                showRecorder = false
            }
        }
    }
}
#endif
