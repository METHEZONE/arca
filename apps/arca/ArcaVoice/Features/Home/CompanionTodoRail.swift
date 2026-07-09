#if os(macOS)
import SwiftUI
import SwiftData
import ArcaVoiceKit

struct CompanionTodoRail: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<TodoTask> { $0.stateRaw != "done" && $0.stateRaw != "failed" && $0.stateRaw != "trashed" },
           sort: \TodoTask.createdAt, order: .reverse) private var openTasks: [TodoTask]
    @Query(sort: \TodoTask.updatedAt, order: .reverse) private var allTasks: [TodoTask]
    @Query(filter: #Predicate<ReplyProposal> { $0.stateRaw == "proposed" },
           sort: \ReplyProposal.createdAt, order: .reverse) private var proposals: [ReplyProposal]
    @AppStorage("autonomyLevel") private var autonomyRaw = AutonomyLevel.readOnly.rawValue
    @State private var draft = ""
    @State private var showProcessed = true

    private var level: AutonomyLevel { AutonomyLevel(rawValue: autonomyRaw) ?? .readOnly }
    private var processed: [TodoTask] {
        allTasks.filter { $0.state == .done || $0.state == .failed }.prefix(8).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("투두", systemImage: "checklist")
                    .font(.system(.headline, design: .rounded, weight: .bold))
                Spacer()
                Text(level.label)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
            }

            quickAdd

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if openTasks.isEmpty {
                        emptyLine("열린 투두가 없어요.")
                    } else {
                        ForEach(openTasks) { task in
                            TodoTaskRow(task: task, level: level)
                        }
                    }

                    processedSection
                    proposalsSection
                }
                .padding(.bottom, 18)
            }
        }
        .padding(16)
        .foregroundStyle(.white)
        .background(Color.white.opacity(0.035))
    }

    private var quickAdd: some View {
        HStack(spacing: 8) {
            TextField("빠르게 맡길 일…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(.callout, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .onSubmit(add)
            Button(action: add) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .white.opacity(0.25) : ArcaSkins.current.hi)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var processedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(duration: 0.25)) { showProcessed.toggle() }
            } label: {
                HStack {
                    Label("자동 처리됨", systemImage: "checkmark.seal.fill")
                    Spacer()
                    Image(systemName: showProcessed ? "chevron.down" : "chevron.right")
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(.green)
            }
            .buttonStyle(.plain)

            if showProcessed {
                if processed.isEmpty {
                    emptyLine("아직 자동 처리 내역이 없어요.")
                } else {
                    ForEach(processed) { task in
                        DisclosureGroup {
                            Text(task.resultMarkdown ?? "결과 내용이 비어 있어요.")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.68))
                                .textSelection(.enabled)
                                .padding(.top, 4)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: task.state == .failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                    .foregroundStyle(task.state == .failed ? .orange : .green)
                                Text(task.title)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer()
                                Text(task.updatedAt, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.42))
                            }
                        }
                        .padding(9)
                        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }

    private var proposalsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("답장 대기", systemImage: "bubble.left.and.text.bubble.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(ArcaSkins.current.hi)
            if proposals.isEmpty {
                emptyLine("승인을 기다리는 답장이 없어요.")
            } else {
                ForEach(proposals) { proposal in
                    ReplyApprovalRow(proposal: proposal)
                }
            }
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.42))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private func add() {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        draft = ""
        let task = TodoTask(title: title)
        context.insert(task)
        try? context.save()
        Task { await TaskEngine.shared.classify(task) }
    }
}
#endif
