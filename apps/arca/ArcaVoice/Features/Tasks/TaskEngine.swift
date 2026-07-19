import Foundation
import SwiftData
import ArcaVoiceKit

/// Classifies tasks (autonomy judgment) and runs the ones ARCA is allowed to
/// "toss" — research/draft via Claude anywhere; send/broad via Codex on the
/// Mac. On iPhone, send/broad tosses queue through the relay and the Mac
/// agent picks them up.
@MainActor
@Observable
final class TaskEngine {
    static let shared = TaskEngine()

    /// How many tosses are executing right now — surfaces drive the
    /// "ARCA is hard at work" states (notch eyes, row faces) off this.
    private(set) var runningCount = 0

    private var anthropicKey: String? {
        let k = KeychainStore.get(.anthropic); return (k?.isEmpty == false) ? k : nil
    }
    private var model: String {
        UserDefaults.standard.string(forKey: "chatModel") ?? "claude-sonnet-5"
    }

    /// Runs ARCA's autonomy judgment for a task and stores the verdict.
    func classify(_ task: TodoTask) async {
        guard let key = anthropicKey else {
            task.autonomyRationale = "No Anthropic key (add one in Settings)"
            return
        }
        do {
            let j = try await AutonomyClassifier(apiKey: key, model: model)
                .classify(title: task.title, detail: task.detail)
            task.actionKind = j.actionKind
            task.urgency = j.urgency
            task.autonomyRationale = j.rationale
            if task.detail.isEmpty { task.detail = j.executionPlan }
            task.touch()
            try? task.modelContext?.save()
            RelaySync.shared.scheduleSync()
        } catch {
            task.autonomyRationale = "Couldn't classify: \(Self.friendlyMessage(for: error))"
        }
    }

    /// Executes a tossable task in the background, streaming progress into its result.
    func toss(_ task: TodoTask) {
        guard task.isTossable() else { return }
        task.state = .running
        task.resultMarkdown = "▸ Starting…"
        task.touch()
        try? task.modelContext?.save()
        // Push the running state now, not just the outcome — the other
        // device gets to watch ARCA actually working.
        RelaySync.shared.scheduleSync()

        Task { @MainActor in
            runningCount += 1
            defer { runningCount -= 1 }
            do {
                switch task.actionKind {
                case .research, .draft:
                    let result = try await runWithClaude(task)
                    task.resultMarkdown = result
                    task.state = .done
                case .send, .broad:
                    #if os(macOS)
                    var log = ""
                    for await line in CodexBridge.run(task: task.detail.isEmpty ? task.title : task.detail) {
                        log += (log.isEmpty ? "" : "\n") + line
                        task.resultMarkdown = String(log.suffix(1500))
                    }
                    task.state = .done
                    #else
                    // The phone can't drive Codex — relay it to the Mac agent.
                    task.state = .tossed
                    task.resultMarkdown = "🛰 Sent to your Mac — ARCA will run it there."
                    #endif
                case .manual:
                    task.state = .needsUser
                }
            } catch {
                task.resultMarkdown = "Failed: \(Self.friendlyMessage(for: error))"
                task.state = .failed
            }
            task.touch()
            try? task.modelContext?.save()
            RelaySync.shared.scheduleSync()
            #if os(macOS)
            if task.state == .done {
                AppServices.shared.notch.celebrate(task.title)
            }
            #endif
        }
    }

    private func runWithClaude(_ task: TodoTask) async throws -> String {
        guard let key = anthropicKey else { throw TaskError.noKey }
        let prompt = task.actionKind == .draft
            ? "Write the deliverable for the following task (email/message/document draft) so it's ready to use as-is. In English. Title: \(task.title). Description: \(task.detail)"
            : "Research and summarize the following task, distilling just the key points. In English. Title: \(task.title). Description: \(task.detail)"
        let messages = [ChatMessage(role: .user, parts: [.text(prompt)])]
        return try await ClaudeChat(apiKey: key, model: model).reply(to: messages, maxTokens: 1200)
    }

    /// Re-runs autonomy judgment for tasks whose last classification failed
    /// (e.g. the API was down or out of credits) so stale error text heals
    /// itself on launch once the underlying problem is fixed.
    func retryFailedClassifications(context: ModelContext) {
        let open = TaskState.open.rawValue
        let descriptor = FetchDescriptor<TodoTask>(
            predicate: #Predicate { $0.stateRaw == open })
        guard let tasks = try? context.fetch(descriptor) else { return }
        let failed = tasks.filter {
            $0.autonomyRationale.hasPrefix("Couldn't classify")
                || $0.autonomyRationale.hasPrefix("분류 실패")
                || $0.autonomyRationale.hasPrefix("No Anthropic key")
        }
        guard !failed.isEmpty else { return }
        Task { @MainActor in
            for task in failed { await classify(task) }
        }
    }

    /// Turns a raw error into a short, user-friendly message.
    private static func friendlyMessage(for error: Error) -> String {
        let description = error.localizedDescription
        if description.lowercased().contains("credit balance") {
            return "Anthropic credit balance is empty — add credits to enable AI features."
        }
        return String(description.prefix(140))
    }

    enum TaskError: Error { case noKey }
}
