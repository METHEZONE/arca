#if os(iOS)
import SwiftUI
import SwiftData
import ArcaVoiceKit

/// Drains the share-extension inbox when the app comes forward and turns each
/// shared item into an action plan (ARCA offering "이거 만들어드릴까요?").
@MainActor
@Observable
final class SharedInboxProcessor {
    private(set) var offering: SharedInbox.Item?
    private(set) var isWorking = false

    func refresh() {
        guard offering == nil, !isWorking else { return }
        offering = SharedInbox.pending().first
    }

    func dismissCurrent() {
        if let offering { SharedInbox.remove(offering) }
        offering = nil
        refresh()
    }

    /// Turns the current shared item into a stored action-plan session.
    @discardableResult
    func generate(modelContext: ModelContext) async -> RecordingSession? {
        guard let item = offering,
              let apiKey = KeychainStore.get(.anthropic), !apiKey.isEmpty else { return nil }
        isWorking = true
        defer { isWorking = false }

        let planner = ClaudeVisionPlanner(apiKey: apiKey)
        do {
            let plan: CapturePlan
            switch item.kind {
            case .image:
                guard let url = SharedInbox.imageURL(for: item) else { return nil }
                let data = try Data(contentsOf: url)
                plan = try await planner.plan(imageData: data, mediaType: "image/jpeg")
            case .text, .url:
                // Reuse the vision planner's schema by sending the text as context
                // with a 1x1 transparent pixel is overkill — instead summarize via
                // a text-only prompt through the same tool. Handled by planText.
                plan = try await planner.planText(item.text ?? "")
            }

            let record = RecordingSession(
                title: (item.kind == .image ? "📸 " : "🔗 ") + plan.title,
                source: .shared)
            record.state = .ready
            let note = SessionNote()
            note.summaryMarkdown = plan.insightMarkdown
            note.actionItemsJSON = try? JSONEncoder().encode(plan.actionItems)
            record.note = note
            modelContext.insert(record)
            try? modelContext.save()

            SharedInbox.remove(item)
            offering = nil
            refresh()
            return record
        } catch {
            return nil
        }
    }
}
#endif
