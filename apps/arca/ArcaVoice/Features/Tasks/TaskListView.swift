#if os(iOS)
import SwiftUI
import SwiftData
import ArcaVoiceKit

private let doneStateRaw = TaskState.done.rawValue
private let trashedStateRaw = TaskState.trashed.rawValue

/// iPhone Tasks tab — the quest log. Toss anything ARCA can run on its own;
/// the rest sits here waiting for you.
struct TaskListView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("autonomyLevel") private var autonomyLevelRaw = AutonomyLevel.readOnly.rawValue
    @State private var draftTitle = ""
    @State private var scope: TaskScope = .open

    @Query(filter: #Predicate<TodoTask> { $0.stateRaw != doneStateRaw && $0.stateRaw != trashedStateRaw },
           sort: \TodoTask.createdAt, order: .reverse)
    private var tasks: [TodoTask]

    @Query(filter: #Predicate<TodoTask> { $0.stateRaw == doneStateRaw },
           sort: \TodoTask.updatedAt, order: .reverse)
    private var completedTasks: [TodoTask]

    @Query(filter: #Predicate<ReplyProposal> { $0.stateRaw == "proposed" || $0.stateRaw == "failed" },
           sort: \ReplyProposal.createdAt, order: .reverse)
    private var proposals: [ReplyProposal]

    private var level: AutonomyLevel { AutonomyLevel(rawValue: autonomyLevelRaw) ?? .readOnly }

    /// ARCA's own triage order: most urgent first, newest first within a tier.
    private var orderedTasks: [TodoTask] {
        tasks.sorted {
            if $0.urgency.rank != $1.urgency.rank { return $0.urgency.rank < $1.urgency.rank }
            return $0.createdAt > $1.createdAt
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                quickAddBar
                scopePicker
                list
            }
            .background {
                ZStack {
                    Color(red: 0.03, green: 0.05, blue: 0.09)
                    Circle().fill(Color(red: 1.0, green: 0.48, blue: 0.1).opacity(0.22))
                        .frame(width: 320, height: 320).blur(radius: 80)
                        .offset(x: -130, y: -230)
                    Circle().fill(Color(red: 0.29, green: 0.62, blue: 1.0).opacity(0.16))
                        .frame(width: 300, height: 300).blur(radius: 90)
                        .offset(x: 150, y: 260)
                }
                .ignoresSafeArea()
            }
            .navigationTitle(L("할 일", "Tasks"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var quickAddBar: some View {
        HStack(spacing: 10) {
            TextField(L("할 일을 적어주세요…", "Add a to-do…"), text: $draftTitle)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular.tint(.black.opacity(0.25)), in: RoundedRectangle(cornerRadius: 16))
                .onSubmit(addTask)
            Button(action: addTask) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(draftTitleIsEmpty ? Color.secondary : ArcaTheme.pixel)
            }
            .disabled(draftTitleIsEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var draftTitleIsEmpty: Bool {
        draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var scopePicker: some View {
        Picker(L("할 일 범위", "Task scope"), selection: $scope) {
            Text(L("진행 중", "Open")).tag(TaskScope.open)
            Text(L("완료", "Done")).tag(TaskScope.done)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private var list: some View {
        List {
            if scope == .open {
                ForEach(proposals) { proposal in
                    ReplyApprovalRow(proposal: proposal)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
                if tasks.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .padding(.top, 30)
                } else {
                    ForEach(orderedTasks) { task in
                        QuestRow(task: task, level: level)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                }
            } else {
                Section {
                    if completedTasks.isEmpty {
                        completedEmptyState
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .padding(.top, 30)
                    } else {
                        ForEach(completedTasks) { task in
                            CompletedQuestRow(task: task)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var completedEmptyState: some View {
        VStack(spacing: 12) {
            SpiritFace(mood: .idle, size: 80)
            Text(L("아직 끝낸 일이 없어요.", "Nothing finished yet."))
                .font(.headline)
                .foregroundStyle(.white)
            Text(L("ARCA가 대신 처리한 일은 결과와 함께 여기 남아요.",
                   "What ARCA handles for you stays here, with the result."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private enum TaskScope: String, Hashable {
        case open
        case done
    }

    private struct CompletedQuestRow: View {
        @Bindable var task: TodoTask
        @Environment(\.modelContext) private var context
        @State private var showingResult = false

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text(task.sourceLabel + task.updatedAt.formatted(
                            .dateTime.month().day().hour().minute()
                                .locale(Locale(identifier: ArcaLanguageResolver.isKorean ? "ko_KR" : "en_US"))))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("다시 열기", "Reopen")) {
                        task.state = .open
                        task.touch()
                        try? context.save()
                        RelaySync.shared.scheduleSync()
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }

                if let result = task.resultMarkdown, !result.isEmpty {
                    Text(result.plainPreview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                    Text(L("눌러서 전체 보기", "Tap to read it all"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(ArcaFace.ember)
                } else {
                    Text(L("직접 끝내셨어요.", "You finished this one."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .contentShape(Rectangle())
            .onTapGesture { if task.resultMarkdown?.isEmpty == false { showingResult = true } }
            .sheet(isPresented: $showingResult) { TaskResultSheet(task: task) }
            .glassEffect(.regular.tint(.black.opacity(0.25)), in: RoundedRectangle(cornerRadius: 18))
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    task.state = .trashed
                    task.touch()
                    try? context.save()
                    RelaySync.shared.scheduleSync()
                } label: {
                    Label(L("삭제", "Delete"), systemImage: "trash")
                }
            }
        }
    }

    private var emptyState: some View {
        ArcaEmptyState(
            title: L("아직 할 일이 없어요", "Nothing to do yet"),
            message: L("적어두거나 회의를 녹음하면 할 일이 여기 모여요. ARCA가 대신 할 수 있는 일은 먼저 물어볼게요.",
                       "Write one above or record a meeting. ARCA asks first about anything it can do for you."))
    }

    private func addTask() {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let task = TodoTask(title: title)
        context.insert(task)
        try? context.save()
        draftTitle = ""
        Task { await TaskEngine.shared.classify(task) }
    }
}

private struct QuestRow: View {
    let task: TodoTask
    let level: AutonomyLevel
    @State private var showingResult = false

    /// ARCA judged it can do this itself and the user hasn't answered yet.
    private var isAsking: Bool { task.state == .open && !task.actionKind.isManual }

    /// One plain line on what "네" will do — not the classifier's reasoning,
    /// which read like an internal log ("…즉시 처리 필요").
    private var planLine: String? {
        guard task.state == .open else { return nil }
        switch task.actionKind {
        case .research: return L("찾아보고 출처와 함께 정리해 드릴게요.", "I'll look it up and summarize it with sources.")
        case .draft, .send: return L("바로 보낼 수 있게 초안을 써 둘게요.", "I'll write a draft you can send as is.")
        case .broad: return L("할 수 있는 데까지 준비해 둘게요.", "I'll get it as far along as I can.")
        case .manual:
            return task.autonomyRationale.isEmpty || task.autonomyRationale.hasPrefix(L("직접", "You"))
                ? nil : L("직접 하셔야 하는 일이에요.", "This one needs you.")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: complete) {
                Circle()
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 1.5)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.arcaPress)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(task.urgency.label)
                        .font(.system(size: 9, weight: .heavy))
                        .tracking(0.8)
                        .foregroundStyle(task.urgency == .someday ? AnyShapeStyle(.secondary) : AnyShapeStyle(urgencyColor))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(urgencyColor.opacity(0.16), in: Capsule())
                    Text(task.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                if let plan = planLine {
                    Text(plan)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                statusLine
                if isAsking { askRow }
            }

            Spacer(minLength: 8)

            trailing
        }
        .padding(14)
        .contentShape(Rectangle())
        .onTapGesture { if task.resultMarkdown?.isEmpty == false { showingResult = true } }
        .sheet(isPresented: $showingResult) { TaskResultSheet(task: task) }
        .onAppear { if isAsking { Self.markAsked(task) } }
        .onChange(of: isAsking) { _, asking in if asking { Self.markAsked(task) } }
        .glassEffect(.regular.tint(urgencyTint), in: RoundedRectangle(cornerRadius: 18))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18)
                .fill(urgencyColor.opacity(task.state == .open ? 0.85 : 0.3))
                .frame(width: 3)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: delete) {
                Label(L("삭제", "Delete"), systemImage: "trash")
            }
            Button(action: complete) {
                Label(L("완료", "Complete"), systemImage: "checkmark")
            }
            .tint(.green)
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch task.state {
        case .running:
            HStack(spacing: 6) {
                    ArcaFace(mood: .working, size: 20, halo: false)
                        .frame(width: 22, height: 22)
                    Text(L("ARCA가 처리 중이에요…", "ARCA is on it…"))
                        .font(.caption)
                        .foregroundStyle(ArcaSkins.current.hi)
                }
        case .failed:
            if let result = task.resultMarkdown {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
        case .done:
            if let result = task.resultMarkdown {
                Text(result.plainPreview)
                    .font(.caption)
                    .foregroundStyle(.secondary.opacity(0.7))
                    .lineLimit(3)
            }
        case .needsUser:
            if let result = task.resultMarkdown, !result.isEmpty {
                Text(L("초안이 준비됐어요. 눌러서 확인하세요.", "Your draft is ready — tap to review."))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ArcaFace.ember)
            }
        case .open, .tossed, .trashed:
            EmptyView()
        }
    }

    /// "대신 처리할까요?" — the user's yes is the permission to act.
    private var askRow: some View {
        HStack(spacing: 8) {
            Text(L("대신 처리할까요?", "Want me to handle it?"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 4)
            Button {
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                BrainClient.track("proposal_rejected")
                task.actionKind = .manual
                task.autonomyRationale = L("직접 하기로 했어요.", "You're handling this one.")
                task.touch()
                try? task.modelContext?.save()
                RelaySync.shared.scheduleSync()
            } label: {
                Text(L("아니요", "No"))
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.white.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                BrainClient.track("proposal_approved")
                TaskEngine.shared.toss(task, approved: true)
            } label: {
                Text(L("네", "Yes"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(ArcaFace.ember, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 4)
    }

    /// Counts each question once for the funnel, however often the row redraws.
    private static func markAsked(_ task: TodoTask) {
        let key = "askedTaskUIDs"
        var asked = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        guard asked.insert(task.uid.uuidString).inserted else { return }
        UserDefaults.standard.set(Array(asked.suffix(500)), forKey: key)
        BrainClient.track("proposal_shown")
    }

    @ViewBuilder private var trailing: some View {
        if task.actionKind == .manual && task.state == .open {
            Image(systemName: "person.fill")
                .foregroundStyle(.secondary)
                .help(L("이건 직접 하셔야 해요", "This one needs you"))
        }
    }

    private var urgencyColor: Color {
        switch task.urgency {
        case .now: return Color(red: 1.0, green: 0.27, blue: 0.23)
        case .today: return Color(red: 1.0, green: 0.58, blue: 0.1)
        case .soon: return Color(red: 1.0, green: 0.84, blue: 0.31)
        case .someday: return Color.white.opacity(0.4)
        }
    }

    /// Glass tint: urgent quests glow warm, calm ones stay neutral-dark.
    private var urgencyTint: Color {
        switch task.urgency {
        case .now: return Color(red: 0.5, green: 0.08, blue: 0.04).opacity(0.35)
        case .today: return Color(red: 0.45, green: 0.22, blue: 0.02).opacity(0.3)
        case .soon, .someday: return .black.opacity(0.25)
        }
    }

    private func complete() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        task.state = .done
        task.touch()
        try? task.modelContext?.save()
        RelaySync.shared.scheduleSync()
    }

    /// Tombstone, not a hard delete — a hard delete resurrects on the next
    /// relay pull because the other side still has the task.
    private func delete() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        task.state = .trashed
        task.touch()
        try? task.modelContext?.save()
        RelaySync.shared.scheduleSync()
    }
}

/// The full result of something ARCA did — read it, copy it, send it on.
private struct TaskResultSheet: View {
    let task: TodoTask
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var result: String { task.resultMarkdown ?? "" }

    var body: some View {
        NavigationStack {
            ScrollView {
                MarkdownText(result)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .navigationTitle(task.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("닫기", "Close")) { dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        UIPasteboard.general.string = result
                        copied = true
                    } label: {
                        Label(copied ? L("복사했어요", "Copied") : L("복사", "Copy"),
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    Spacer()
                    ShareLink(item: result) {
                        Label(L("보내기", "Share"), systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }
}

private extension String {
    /// Result text for a two-line preview: markdown marks and links stripped.
    var plainPreview: String {
        var out = replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(\*\*|__|`|^#+\s*)"#, with: "", options: [.regularExpression])
        out = out.replacingOccurrences(of: #"(?m)^#+\s*"#, with: "", options: .regularExpression)
        return out.replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
    }
}

private extension TodoTask {
    /// Where a to-do came from, in words a tester knows.
    var sourceLabel: String {
        if sourceRaw.hasPrefix("meeting:") { return L("회의에서 · ", "From a meeting · ") }
        if sourceRaw == "user" { return "" }
        return ""
    }
}

#Preview {
    TaskListView()
        .modelContainer(for: TodoTask.self, inMemory: true)
}
#endif
