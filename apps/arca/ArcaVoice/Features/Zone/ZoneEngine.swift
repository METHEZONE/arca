#if os(macOS)
import Foundation
import SwiftData
import AppKit
import ArcaVoiceKit

/// ZONE mode: while on, ARCA guards your focus. It enables Do Not Disturb,
/// polls your connected sources (Gmail/Slack/calendar via Composio) for incoming
/// items, auto-handles the ones it's allowed to, and queues the rest. When ZONE
/// ends it reports both sides — what it handled, and what still needs you —
/// the latter as a sequence of RPG-style choice cards.
///
/// Note: macOS doesn't let an app intercept *other apps'* system notifications,
/// so "eating notifications" is realized as DND + source polling + queueing.
@MainActor
@Observable
final class ZoneEngine {
    struct HandledItem: Identifiable, Sendable {
        let id = UUID()
        var summary: String
        var action: String
    }
    struct AttentionItem: Identifiable, Sendable {
        let id = UUID()
        var title: String
        var context: String
        var choices: [Choice]
    }
    struct Choice: Identifiable, Sendable {
        let id = UUID()
        var label: String
        var explanation: String
        var isRecommended: Bool
        /// What ARCA does if picked (executionPlan for Codex/Claude), or nil for "직접 처리".
        var executionPlan: String?
    }

    private(set) var isActive = false
    private(set) var startedAt: Date?
    private(set) var handled: [HandledItem] = []
    private(set) var attention: [AttentionItem] = []
    /// When set, the end-of-zone report sheet is shown.
    var showReport = false

    private var pollTask: Task<Void, Never>?
    private var container: ModelContainer?

    func configure(container: ModelContainer) { self.container = container }

    func start() {
        guard !isActive else { return }
        isActive = true
        startedAt = .now
        handled = []
        attention = []
        FocusMode.setDoNotDisturb(true)
        AppServices.shared.notch.zoneChanged(true)

        pollTask = Task { @MainActor in
            while isActive && !Task.isCancelled {
                await pollOnce()
                try? await Task.sleep(for: .seconds(90))
            }
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        pollTask?.cancel()
        pollTask = nil
        FocusMode.setDoNotDisturb(false)
        AppServices.shared.notch.zoneChanged(false)
        showReport = true
    }

    /// One polling pass: pull recent inbound items, classify, auto-handle or queue.
    private func pollOnce() async {
        guard let key = KeychainStore.get(.anthropic), !key.isEmpty else { return }
        let items = await ZoneSources.recentInbound(limit: 8)
        let model = UserDefaults.standard.string(forKey: "chatModel") ?? "claude-sonnet-5"
        let classifier = AutonomyClassifier(apiKey: key, model: model)

        for item in items {
            do {
                let j = try await classifier.classify(title: item.title, detail: item.body)
                let level = AutonomyLevel.current
                if !j.actionKind.isManual, level != .off, level.rawValue >= j.actionKind.minimumAutonomy.rawValue {
                    // ARCA handles it now.
                    handled.append(HandledItem(summary: item.title, action: j.rationale))
                } else {
                    // Needs the user — build a choice card.
                    let choices = try await buildChoices(for: item, key: key, model: model)
                    attention.append(AttentionItem(title: item.title, context: item.body, choices: choices))
                }
            } catch {
                attention.append(AttentionItem(
                    title: item.title, context: item.body,
                    choices: [Choice(label: "Later", explanation: "Skip for now", isRecommended: false, executionPlan: nil)]))
            }
        }
    }

    /// Ask Claude for 2–3 next-step choices with a recommendation, interview-style.
    private func buildChoices(for item: ZoneSources.Inbound, key: String, model: String) async throws -> [Choice] {
        let tool: [String: Any] = [
            "name": "offer_choices",
            "description": "Offer the user 2-3 next-step choices for an incoming item.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "choices": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "label": ["type": "string", "description": "Short choice label, in English"],
                                "explanation": ["type": "string", "description": "One-line explanation of what this choice does, in English"],
                                "isRecommended": ["type": "boolean"],
                                "arcaCanDo": ["type": "boolean", "description": "Whether ARCA can execute this choice on the user's behalf"],
                                "executionPlan": ["type": "string", "description": "If arcaCanDo is true, the instruction ARCA should follow; otherwise an empty string"],
                            ],
                            "required": ["label", "explanation", "isRecommended", "arcaCanDo", "executionPlan"],
                        ],
                    ],
                ],
                "required": ["choices"],
            ] as [String: Any],
        ]
        let userText = "Give the user 2-3 next-step choices for the following incoming item so they can decide quickly. Mark one as recommended. Include a one-line explanation for each choice, in English. Title: \(item.title)\nContent: \(item.body)"
        let body: [String: Any] = [
            "model": model, "max_tokens": 700,
            "tools": [tool], "tool_choice": ["type": "tool", "name": "offer_choices"],
            "messages": [["role": "user", "content": [["type": "text", "text": userText]]]],
        ]
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await uploadBody(URLSession.shared, for: request, body: payload)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let tu = content.first(where: { ($0["type"] as? String) == "tool_use" }),
              let input = tu["input"] as? [String: Any],
              let raw = input["choices"] as? [[String: Any]] else {
            return [Choice(label: "I'll check it myself", explanation: "Open the original and handle it directly", isRecommended: true, executionPlan: nil)]
        }
        return raw.map { d in
            let canDo = (d["arcaCanDo"] as? Bool) ?? false
            let plan = (d["executionPlan"] as? String) ?? ""
            return Choice(
                label: (d["label"] as? String) ?? "Choice",
                explanation: (d["explanation"] as? String) ?? "",
                isRecommended: (d["isRecommended"] as? Bool) ?? false,
                executionPlan: (canDo && !plan.isEmpty) ? plan : nil)
        }
    }

    /// Bring-up hook (ARCA_SELFTEST_ZONEREPORT): renders the report with fake
    /// data so the window/quest-card UI can be verified without live sources.
    func seedDemoReport() {
        startedAt = .now.addingTimeInterval(-52 * 60)
        handled = [
            HandledItem(summary: "📧 3 newsletters", action: "Promotional, no need to read — cleared them out"),
            HandledItem(summary: "📧 Meeting notes share request — PM Kim", action: "Prepared a draft summary of the last meeting"),
        ]
        attention = [
            AttentionItem(
                title: "📧 Contract review request — Legal team",
                context: "Review ZER01NE sprint contract v3 and reply by Friday",
                choices: [
                    Choice(label: "Delegate a draft reply", explanation: "ARCA will summarize the review points and prepare a draft reply",
                           isRecommended: true, executionPlan: "Draft a reply with a summary of key contract clauses and a list of questions"),
                    Choice(label: "I'll check it myself", explanation: "Open the original and handle it directly", isRecommended: false, executionPlan: nil),
                ]),
            AttentionItem(
                title: "📅 Tomorrow's 10am meeting — reschedule request",
                context: "The other party asked if 11am works instead",
                choices: [
                    Choice(label: "Move to 11am", explanation: "ARCA will move the calendar event and send the acceptance reply",
                           isRecommended: true, executionPlan: "Move the calendar event to 11am and send an acceptance reply"),
                    Choice(label: "I'll check it myself", explanation: "Open the original and handle it directly", isRecommended: false, executionPlan: nil),
                ]),
        ]
        showReport = true
    }

    /// The user picked a choice in the report — run it if ARCA can, then drop it.
    func resolve(_ item: AttentionItem, choice: Choice) {
        attention.removeAll { $0.id == item.id }
        guard let plan = choice.executionPlan, let container else { return }
        // Log it as a running task ARCA is handling.
        let task = TodoTask(title: item.title, detail: plan, actionKind: .broad,
                            autonomyRationale: "Approved from the ZONE report", source: "zone")
        container.mainContext.insert(task)
        try? container.mainContext.save()
        TaskEngine.shared.toss(task)
    }
}
#endif
