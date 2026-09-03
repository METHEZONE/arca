#if os(macOS)
import SwiftUI
import SwiftData
import ArcaVoiceKit

/// Section titles and symbols now come from `ArcaSection`, shared with the
/// iPhone, so the two apps can't drift into calling the same thing by different
/// names again.
typealias CompanionHomeMode = ArcaSection

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
        case 5..<11: timeWord = L("좋은 아침이에요", "Good morning")
        case 11..<17: timeWord = L("좋은 오후예요", "Good afternoon")
        case 17..<22: timeWord = L("좋은 저녁이에요", "Good evening")
        default: timeWord = L("고요한 밤이에요", "Quiet night")
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
            L("우리가 함께한 지 D+\(dayCount)일째예요. 기억 \(memoryCount)개를 모았어요.",
              "Day D+\(dayCount) together. I've gathered \(memoryCount) memories."),
            L("D+\(dayCount), 당신의 조각 \(memoryCount)개를 품고 있어요.",
              "D+\(dayCount) — I'm holding \(memoryCount) pieces of you."),
            L("처음 만난 날부터 \(memoryCount)개의 기억이 쌓였어요.",
              "\(memoryCount) memories have piled up since the day we met."),
        ]
        return variants[abs(dayCount + memoryCount) % variants.count]
    }
}

struct CompanionHomeView: View {
    @State private var services = AppServices.shared
    @State private var vitals = VitalsEngine.shared
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
    @State private var heroActivity: ArcaFace.Activity?

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
        // Recording failures were invisible on the Mac — same silent-death
        // class the iPhone home had. Now they land as a dismissible banner.
        .overlay(alignment: .top) {
            if let error = services.coordinator.errorMessage {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.callout)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        services.coordinator.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(.arcaPress)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.orange.opacity(0.5)))
                .padding(.top, 12)
                .padding(.horizontal, 20)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: services.coordinator.errorMessage != nil)
        .toolbar { toolbar }
        .onAppear { StorageJanitor.shared.runIfDue(context: modelContext) }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
        }
        .sheet(isPresented: $showSkins) {
            SkinsView()
                .frame(minWidth: 520, minHeight: 520)
        }
        .alert(L("새 프로젝트", "New project"), isPresented: Binding(
            get: { projectDialogConversationId != nil },
            set: { if !$0 { projectDialogConversationId = nil } }
        )) {
            TextField(L("프로젝트 이름", "Project name"), text: $newProjectName)
            Button(L("지정", "Assign")) {
                if let id = projectDialogConversationId {
                    assignProject(newProjectName, to: id)
                }
                projectDialogConversationId = nil
                newProjectName = ""
            }
            Button(L("취소", "Cancel"), role: .cancel) {
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
                Label(L("오른쪽 레일", "Right rail"), systemImage: "sidebar.right")
            }
        }
        // 녹음은 핵심 기능 — 어떤 모드에서도 ⌘N 한 번에 시작된다.
        ToolbarItem(placement: .primaryAction) {
            Button {
                startNewRecording()
            } label: {
                Label(L("새 녹음", "New Recording"), systemImage: "mic.badge.plus")
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
                ForEach(ArcaSection.macSidebar) { item in
                    sidebarButton(mode: item)
                }
            }
            .padding(.horizontal, 10)

            DevicePresenceBar()
                .padding(.horizontal, 16)

            HStack {
                Text(L("채팅", "Chats"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button {
                    startEmptyChat()
                } label: {
                    Label(L("새 채팅", "New chat"), systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.arcaPress)
                .foregroundStyle(ArcaSkins.current.hi)
            }
            .padding(.horizontal, 16)

            chatList

            Spacer()

            Button {
                showSettings = true
            } label: {
                Label(L("설정", "Settings"), systemImage: "gearshape")
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.arcaPress)
            .padding(16)
        }
    }

    private func sidebarButton(mode item: CompanionHomeMode) -> some View {
        Button {
            // Sidebar nav fires tens of times a session — kept brief so
            // repeated clicks never feel like they're waiting on the UI.
            withAnimation(.spring(duration: 0.18)) {
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
        .buttonStyle(.arcaPress)
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
                Text(L("\(conversation.count)턴 · \(conversation.lastAt.formatted(date: .omitted, time: .shortened))",
                       "\(conversation.count) turns · \(conversation.lastAt.formatted(date: .omitted, time: .shortened))"))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.38))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(activeConversationId == conversation.id ? .white.opacity(0.11) : .white.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.arcaPress)
        .contextMenu {
            Menu(L("프로젝트 지정", "Assign project")) {
                ForEach(projectNames, id: \.self) { project in
                    Button(project) { assignProject(project, to: conversation.id) }
                }
                Divider()
                Button(L("새 프로젝트…", "New project…")) {
                    newProjectName = ""
                    projectDialogConversationId = conversation.id
                }
            }
            Button(L("삭제", "Delete"), role: .destructive) {
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
        case .condition:
            VitalsView()
        case .tasks:
            // Todos live in the permanent right-hand rail on the Mac; this only
            // fires if the sidebar list ever grows to include the section.
            CompanionTodoRail()
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
        case .skills:
            SkillsView { prompt in
                // "Try it" drops the sample request into a fresh chat and sends it.
                startEmptyChat()
                mode = .home
                chat.draftText = prompt
                chat.send()
            }
        case .shop:
            ShopView()
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
                ArcaFace(mood: coordinator.phase == .idle ? .idle : .listening, size: 180,
                         halo: true, followsPointer: true, activities: true,
                         onActivity: { activity in
                             withAnimation(.spring(duration: 0.35)) { heroActivity = activity }
                         })
                    .frame(width: 210, height: 210)
            }
            .buttonStyle(.arcaPress)
            .overlay(alignment: .bottom) {
                if let heroActivity {
                    Text(heroActivity.caption)
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.white.opacity(0.08), in: Capsule())
                        .offset(y: 14)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .help(L("ARCA를 누르면 바로 녹음이 시작돼요", "Tap ARCA and recording starts right away"))

            VStack(spacing: 8) {
                Text(CompanionHomeViewModel.greeting(ownerName: services.ownerName))
                    .font(.system(.title2, design: .rounded, weight: .bold))
                Text(remark.text.isEmpty
                     ? L("오늘도 당신의 기억을 지키고 있어요.", "I'm keeping your memories safe today too.")
                     : remark.text)
                    .font(.system(.headline, design: .rounded, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))

            recordCTA
            statsRow

            // Same two cards the iPhone home shows, from the same data.
            HStack(alignment: .top, spacing: ArcaSpacing.md) {
                MorningMomentCard { mode = .condition }
                RecoveredTimeCard()
            }
            .frame(maxWidth: 760)

            recentHighlights
            Spacer(minLength: 18)
            CompanionDraftComposer(placeholder: L("ARCA에게 말 걸기…", "Talk to ARCA…")) { text in
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
            Label(coordinator.phase == .idle
                    ? L("녹음 시작", "Start recording")
                    : L("녹음 중 — 열기", "Recording — open it"),
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
        .buttonStyle(.arcaPress)
    }

    private var statsRow: some View {
        let earliest = CompanionHomeViewModel.earliestDate(sessions: sessions, facts: facts, chatEntries: chatLog)
        let dayCount = CompanionHomeLogic.dayCount(since: earliest)
        return HStack(spacing: 10) {
            statChip(L("함께한 지 D+\(dayCount)일", "D+\(dayCount) together"),
                     systemImage: "calendar.badge.clock")
            statChip(L("기억 \(facts.count)개", "\(facts.count) memories"),
                     systemImage: "brain.head.profile")
            statChip(L("세션 \(sessions.count)개", "\(sessions.count) sessions"),
                     systemImage: "waveform")
            Button {
                withAnimation(.spring(duration: 0.18)) { mode = .condition }
            } label: {
                statChip(vitals.ringScore.map { L("몰입 \($0)", "Focus \($0)") }
                         ?? L("컨디션", "Condition"),
                         systemImage: "bolt.heart")
            }
            .buttonStyle(.arcaPress)
            Button {
                showSkins = true
            } label: {
                statChip(L("스킨", "Skins"), systemImage: "sparkles")
            }
            .buttonStyle(.arcaPress)
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
                .buttonStyle(.arcaPress)
            }
        }
    }

    private var memoryPane: some View {
        VStack(spacing: 12) {
            TextField(L("기억 검색…", "Search memories…"), text: $memorySearch)
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
        let ungrouped = L("일반", "General")
        let grouped = Dictionary(grouping: summaries) { $0.projectName ?? ungrouped }
        return grouped.keys.sorted { lhs, rhs in
            if lhs == ungrouped { return false }
            if rhs == ungrouped { return true }
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
                    Label(L("홈으로", "Back home"), systemImage: "chevron.left")
                        .font(.system(.callout, design: .rounded, weight: .semibold))
                }
                .buttonStyle(.arcaPress)
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(chat.messages) { message in
                            ChatBubbleView(message: message, onSaveNote: { text in saveAsNote(text) })
                                .id(message.id)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .onChange(of: chat.messages.last?.id) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
                }
                // Keep the live turn in view as thoughts and text stream in.
                .onChange(of: chat.messages.last?.parts.count) { _, _ in
                    guard let id = chat.messages.last?.id else { return }
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }

            CompanionChatInput(text: $chat.draftText, disabled: chat.isThinking) {
                chat.send()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
    }

    /// The artifact path: a long answer becomes a markdown note in the vault
    /// (or ~/Documents/ARCA) and is revealed in Finder.
    private func saveAsNote(_ text: String) {
        let title = text.split(separator: "\n").first.map { String($0.trimmingCharacters(in: CharacterSet(charactersIn: "# *"))).prefix(60) } ?? "ARCA note"
        if let url = try? ChatToolbox.saveNote(title: String(title), markdown: text) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

private struct CompanionChatInput: View {
    @Binding var text: String
    var disabled: Bool
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TextField(L("메시지 입력…", "Type a message…"), text: $text, axis: .vertical)
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
            .buttonStyle(.arcaPress)
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
                Label(L("보내기", "Send"), systemImage: "arrow.up.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .white.opacity(0.24) : ArcaSkins.current.hi)
            }
            .buttonStyle(.arcaPress)
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
                // A recording in progress no longer locks the pane: pick another
                // note and its transcript opens, with a pill to jump back to the
                // live recorder. The recorder shows when nothing else is chosen.
                if showRecorder || (coordinator.phase != .idle && selectedSession == nil) {
                    RecordView { saved in
                        showRecorder = false
                        selectedSession = saved
                    }
                } else if let selectedSession {
                    SessionDetailView(session: selectedSession)
                        .overlay(alignment: .top) {
                            if coordinator.phase != .idle {
                                Button {
                                    self.selectedSession = nil
                                    showRecorder = true
                                } label: {
                                    HStack(spacing: 8) {
                                        Circle().fill(ArcaTheme.recording).frame(width: 8, height: 8)
                                        Text(L("녹음 진행 중 — 녹음 화면으로", "Recording — back to the live view"))
                                            .font(.caption.weight(.semibold))
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(.black.opacity(0.75), in: Capsule())
                                    .overlay(Capsule().strokeBorder(ArcaTheme.recording.opacity(0.5)))
                                }
                                .buttonStyle(.arcaPress)
                                .padding(.top, 10)
                            }
                        }
                } else {
                    ContentUnavailableView(
                        L("녹음을 고르거나 새로 시작하세요", "Select a recording or start a new one"),
                        systemImage: "waveform.badge.mic",
                        description: Text(L("⌘N을 누르면 바로 녹음이 시작돼요.",
                                            "Press ⌘N to start recording right away."))
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 세션을 클릭하면 녹음 대기 화면이 아니라 그 세션의 전사가 보여야 한다.
        .onChange(of: selectedSession) { _, newValue in
            if newValue != nil { showRecorder = false }
        }
    }
}
#endif
