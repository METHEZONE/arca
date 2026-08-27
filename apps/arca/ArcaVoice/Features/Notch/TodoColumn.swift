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
    @Query(filter: #Predicate<ReplyProposal> { $0.stateRaw == "failed" },
           sort: \ReplyProposal.createdAt, order: .reverse) private var failedProposals: [ReplyProposal]
    @Query private var sentProposals: [ReplyProposal]
    @AppStorage("autonomyLevel") private var autonomyRaw = AutonomyLevel.readOnly.rawValue
    // Unused in the body; forces a re-render when the app language changes.
    @AppStorage(ArcaLang.defaultsKey) private var appLanguage = "system"
    @State private var draft = ""
    @State private var showSuggestions = false

    init() {
        // Bound the sent-report query in the predicate — an unbounded query
        // would materialize every proposal ever sent on each store change.
        let cutoff = Date.now.addingTimeInterval(-24 * 3600)
        let floor = Date.distantPast
        _sentProposals = Query(
            filter: #Predicate<ReplyProposal> {
                $0.stateRaw == "sent" && ($0.sentAt ?? floor) >= cutoff
            },
            sort: \ReplyProposal.sentAt, order: .reverse)
    }

    private var level: AutonomyLevel { AutonomyLevel(rawValue: autonomyRaw) ?? .readOnly }
    private var humanTasks: [TodoTask] {
        tasks.filter(TodoTriage.needsHuman).sorted(by: TodoTriage.humanOrder)
    }
    private var suggestions: [TodoTask] {
        tasks.filter { !TodoTriage.needsHuman($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L("Tasks", ko: "할 일"), systemImage: "checklist")
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
                    if !proposals.isEmpty {
                        Label(L("Waiting for your word", ko: "승인 대기"),
                              systemImage: "hand.raised.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(ArcaSkins.current.mid)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(proposals) { proposal in
                        ReplyApprovalRow(proposal: proposal)
                    }
                    ForEach(failedProposals) { proposal in
                        failedRow(proposal)
                    }
                    if !recentReports.isEmpty {
                        reportsSection
                    }
                    ForEach(humanTasks) { task in
                        TodoTaskRow(task: task, level: level)
                    }
                    if !suggestions.isEmpty {
                        Button {
                            withAnimation(.spring(duration: 0.25)) { showSuggestions.toggle() }
                        } label: {
                            HStack {
                                Label(L("ARCA suggests \(suggestions.count)",
                                        ko: "ARCA 제안 \(suggestions.count)"),
                                      systemImage: "sparkles")
                                Spacer()
                                Image(systemName: showSuggestions ? "chevron.down" : "chevron.right")
                            }
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.5))
                        }
                        .buttonStyle(.arcaPress)
                        if showSuggestions {
                            ForEach(suggestions) { task in
                                TodoTaskRow(task: task, level: level)
                            }
                        }
                    }
                    if !completed.isEmpty {
                        completedSection
                    }
                }
            }
            .overlay {
                if tasks.isEmpty && proposals.isEmpty && completed.isEmpty {
                    Text(L("Add a task —\nanything ARCA can handle itself\ngets a Toss button.",
                           ko: "할 일을 추가해 보세요 —\nARCA가 스스로 처리할 수 있는 건\nToss 버튼이 붙어요."))
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .padding(.leading, 12)
    }

    /// What ARCA already handled (last 24h) — the "나 이거 처리했어!" report.
    private var recentReports: [ReplyProposal] {
        Array(sentProposals.prefix(3))
    }

    /// A send that failed must stay visible with a way to retry — a card that
    /// silently vanishes reads as "handled" when it wasn't.
    private func failedRow(_ proposal: ReplyProposal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text(proposal.question
                     ?? L("Reply to \(proposal.author)", ko: "\(proposal.author)에 회신"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                Spacer()
            }
            HStack(spacing: 8) {
                Text(L("Send failed", ko: "전송 실패"))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                Spacer()
                Button(L("Dismiss", ko: "넘기기")) {
                    AmbientOps.shared.skip(proposal, context: context)
                }
                .buttonStyle(.arcaPress)
                .font(.caption2)
                .foregroundStyle(.secondary)
                Button {
                    Task { @MainActor in
                        await AmbientOps.shared.approve(proposal, context: context)
                    }
                } label: {
                    Text(L("Retry", ko: "다시 시도"))
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(.orange.opacity(0.85), in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.arcaPress)
            }
        }
        .padding(10)
        .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(.orange.opacity(0.3), lineWidth: 1)
        }
    }

    private var reportsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("Handled for you", ko: "처리했어요"), systemImage: "checkmark.seal.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.green)
            ForEach(recentReports) { proposal in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: proposal.autoSent ? "sparkles" : "paperplane.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.green.opacity(0.8))
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(proposal.question
                             ?? L("Replied to \(proposal.author)", ko: "\(proposal.author)에 회신"))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(2)
                        HStack(spacing: 5) {
                            if proposal.autoSent {
                                Text(L("auto-handled", ko: "자동 처리"))
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                                    .background(.green.opacity(0.18), in: Capsule())
                                    .foregroundStyle(.green)
                            }
                            if let attachment = proposal.attachmentName {
                                Label(attachment, systemImage: "paperclip")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .lineLimit(1)
                            }
                            if let sentAt = proposal.sentAt {
                                Text(sentAt, style: .relative)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .padding(.top, 2)
    }

    private var addBar: some View {
        HStack(spacing: 6) {
            TextField(L("Add a task…", ko: "할 일 추가…"), text: $draft)
                .textFieldStyle(.plain)
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                .onSubmit(add)
            Button(action: add) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(draft.isEmpty ? .white.opacity(0.3) : ArcaTheme.idle)
            }
            .buttonStyle(.arcaPress)
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
            Label(L("Completed", ko: "완료"), systemImage: "checkmark.seal.fill")
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
                .buttonStyle(.arcaPress)

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.callout)
                        .strikethrough(task.state == .done)
                    if task.dueAt != nil || task.urgency == .now || task.urgency == .today {
                        HStack(spacing: 5) {
                            if task.urgency == .now || task.urgency == .today {
                                Text(task.urgency.label)
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                                    .background(ArcaSkins.current.hi.opacity(0.22), in: Capsule())
                                    .foregroundStyle(ArcaSkins.current.hi)
                            }
                            if let due = task.dueAt {
                                let label = TodoTriage.dueLabel(for: due)
                                Label(label.text, systemImage: "calendar")
                                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                                    .background(label.tint.opacity(0.18), in: Capsule())
                                    .foregroundStyle(label.tint)
                            }
                        }
                        .padding(.top, 1)
                    }
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
                    .buttonStyle(.arcaPress)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
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
                Text(L("ARCA is on it…", ko: "ARCA가 처리 중…")).font(.caption2)
                    .foregroundStyle(ArcaSkins.current.hi)
            }
        case .done where task.resultMarkdown != nil:
            Text(task.resultMarkdown ?? "").font(.caption2)
                .foregroundStyle(.white.opacity(0.6)).lineLimit(3)
        case .failed:
            Text(task.resultMarkdown ?? L("Failed", ko: "실패")).font(.caption2).foregroundStyle(.orange)
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
            .buttonStyle(.arcaPress)
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
