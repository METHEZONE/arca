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

    @Query(filter: #Predicate<ReplyProposal> { $0.stateRaw == "proposed" },
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
            .navigationTitle("Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text(level.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var quickAddBar: some View {
        HStack(spacing: 10) {
            TextField("Toss me a quest…", text: $draftTitle)
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
        Picker("Task scope", selection: $scope) {
            Text("Open").tag(TaskScope.open)
            Text("Done").tag(TaskScope.done)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private var list: some View {
        List {
            BriefingCard()
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))

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
                } footer: {
                    Text("Completed tasks stay in SwiftData on this device and sync through the arca-brain relay as tasks.json when relay sync is configured.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                        .padding(.horizontal, 16)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var completedEmptyState: some View {
        VStack(spacing: 12) {
            SpiritFace(mood: .idle, size: 80)
            Text("No completed quests yet.")
                .font(.headline)
                .foregroundStyle(.white)
            Text("When ARCA finishes something, the result and source stay here.")
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
                        HStack(spacing: 3) {
                            Text("source: \(task.sourceRaw) ·")
                            Text(task.updatedAt, style: .relative)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reopen") {
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
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(8)
                } else {
                    Text("Marked complete manually. No ARCA result log was attached.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .glassEffect(.regular.tint(.black.opacity(0.25)), in: RoundedRectangle(cornerRadius: 18))
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    task.state = .trashed
                    task.touch()
                    try? context.save()
                    RelaySync.shared.scheduleSync()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            SpiritFace(mood: .idle, size: 90)
            Text("No quests yet.")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Add one — anything I can do myself gets a Toss button.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
            Spacer()
        }
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
                if !task.autonomyRationale.isEmpty {
                    Text(task.autonomyRationale)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                statusLine
            }

            Spacer(minLength: 8)

            trailing
        }
        .padding(14)
        .glassEffect(.regular.tint(urgencyTint), in: RoundedRectangle(cornerRadius: 18))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18)
                .fill(urgencyColor.opacity(task.state == .open ? 0.85 : 0.3))
                .frame(width: 3)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: delete) {
                Label("Delete", systemImage: "trash")
            }
            Button(action: complete) {
                Label("Complete", systemImage: "checkmark")
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
                    Text("ARCA is on it…")
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
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary.opacity(0.7))
                    .lineLimit(3)
            }
        case .open, .tossed, .needsUser, .trashed:
            EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        if task.isTossable(at: level) && task.state == .open {
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                TaskEngine.shared.toss(task)
            } label: {
                Text("Toss")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(ArcaTheme.pixel, in: Capsule())
            }
        } else if task.actionKind == .manual {
            Image(systemName: "person.fill")
                .foregroundStyle(.secondary)
                .help("This one needs you")
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

#Preview {
    TaskListView()
        .modelContainer(for: TodoTask.self, inMemory: true)
}
#endif
