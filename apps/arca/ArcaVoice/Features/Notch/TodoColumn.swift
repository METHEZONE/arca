#if os(macOS)
import SwiftUI
import SwiftData
import ArcaVoiceKit

/// The to-do tracker in the dashboard: quick-add, live status, and a "Toss"
/// button on anything ARCA judged it can run autonomously at your trust level.
struct TodoColumn: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<TodoTask> { $0.stateRaw != "done" && $0.stateRaw != "trashed" },
           sort: \TodoTask.createdAt, order: .reverse) private var tasks: [TodoTask]
    @Query(filter: #Predicate<TodoTask> { $0.stateRaw == "done" },
           sort: \TodoTask.updatedAt, order: .reverse) private var completed: [TodoTask]
    @Query(filter: #Predicate<ReplyProposal> { $0.stateRaw == "proposed" },
           sort: \ReplyProposal.createdAt, order: .reverse) private var proposals: [ReplyProposal]
    @AppStorage("autonomyLevel") private var autonomyRaw = AutonomyLevel.readOnly.rawValue
    @State private var draft = ""

    private var level: AutonomyLevel { AutonomyLevel(rawValue: autonomyRaw) ?? .readOnly }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Tasks", systemImage: "checklist")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text(level.label)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.top, 6)

            addBar

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(proposals) { proposal in
                        ReplyApprovalRow(proposal: proposal)
                    }
                    ForEach(tasks) { task in
                        TodoTaskRow(task: task, level: level)
                    }
                    if !completed.isEmpty {
                        completedSection
                    }
                }
            }
            .overlay {
                if tasks.isEmpty && proposals.isEmpty && completed.isEmpty {
                    Text("Add a task —\nanything ARCA can handle itself\ngets a Toss button.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .padding(.leading, 12)
    }

    private var addBar: some View {
        HStack(spacing: 6) {
            TextField("Add a task…", text: $draft)
                .textFieldStyle(.plain)
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                .onSubmit(add)
            Button(action: add) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(draft.isEmpty ? .white.opacity(0.3) : ArcaTheme.idle)
            }
            .buttonStyle(.plain)
            .disabled(draft.isEmpty)
        }
    }

    private func add() {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        draft = ""
        let task = TodoTask(title: title)
        context.insert(task)
        try? context.save()
        // ARCA judges autonomy in the background.
        Task { await TaskEngine.shared.classify(task) }
    }

    private var completedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Completed", systemImage: "checkmark.seal.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.green)
            ForEach(completed.prefix(3)) { task in
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                    if let result = task.resultMarkdown, !result.isEmpty {
                        Text(result)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(2)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .padding(.top, 4)
    }
}

struct TodoTaskRow: View {
    @Bindable var task: TodoTask
    let level: AutonomyLevel
    @Environment(\.modelContext) private var context
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    task.state = .done
                    task.touch()
                    try? context.save()
                    RelaySync.shared.scheduleSync()
                } label: {
                    Image(systemName: task.state == .done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.callout)
                        .strikethrough(task.state == .done)
                    if !task.autonomyRationale.isEmpty {
                        Text(task.autonomyRationale)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(2)
                    }
                    statusLine
                }
                Spacer(minLength: 4)
                if hovering {
                    Button {
                        withAnimation(.spring(duration: 0.3)) {
                            task.state = .trashed
                            task.touch()
                            try? context.save()
                        }
                        RelaySync.shared.scheduleSync()
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(width: 20, height: 20)
                            .background(.white.opacity(0.1), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
                    .help("Delete — won't be tossed, won't come back")
                }
                tossButton
            }
        }
        .padding(10)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 11))
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch task.state {
        case .running:
            HStack(spacing: 6) {
                ArcaFace(mood: .working, size: 18, halo: false)
                    .frame(width: 20, height: 20)
                Text("ARCA is on it…").font(.caption2)
                    .foregroundStyle(ArcaSkins.current.hi)
            }
        case .done where task.resultMarkdown != nil:
            Text(task.resultMarkdown ?? "").font(.caption2)
                .foregroundStyle(.white.opacity(0.6)).lineLimit(3)
        case .failed:
            Text(task.resultMarkdown ?? "Failed").font(.caption2).foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var tossButton: some View {
        if task.isTossable(at: level) && task.state == .open {
            Button {
                TaskEngine.shared.toss(task)
            } label: {
                Text("Toss")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(ArcaTheme.idle, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("ARCA can run this: \(task.autonomyRationale)")
        } else if task.actionKind == .manual && task.state == .open && !task.autonomyRationale.isEmpty {
            Image(systemName: "person.fill")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.35))
                .help("This one needs you")
        }
    }
}
#endif
