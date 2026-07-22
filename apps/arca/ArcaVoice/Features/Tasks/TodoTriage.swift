import Foundation
import SwiftData
import SwiftUI
import ArcaVoiceKit

/// Keeps the to-do rail meaningful: separates what the human actually has to
/// look at from ARCA's harvested suggestions, and quietly retires suggestions
/// that have gone stale — an untouched three-day-old "check this notification"
/// task is noise, not work.
enum TodoTriage {
    /// The user typed this themselves (quick-add on any device).
    static func isHuman(_ task: TodoTask) -> Bool {
        task.sourceRaw == "user" || task.sourceRaw == "iphone" || task.sourceRaw == "mac"
    }

    /// Belongs in the "needs you" section: human-entered, inherently manual,
    /// or explicitly waiting on the user.
    static func needsHuman(_ task: TodoTask) -> Bool {
        isHuman(task) || task.actionKind == .manual || task.state == .needsUser
    }

    /// Sort for the "needs you" section: overdue/urgent first, then by due
    /// date, then newest.
    static func humanOrder(_ a: TodoTask, _ b: TodoTask) -> Bool {
        if a.urgency.rank != b.urgency.rank { return a.urgency.rank < b.urgency.rank }
        switch (a.dueAt, b.dueAt) {
        case let (da?, db?) where da != db: return da < db
        case (.some, nil): return true
        case (nil, .some): return false
        default: return a.createdAt > b.createdAt
        }
    }

    /// D-day chip: text + tint for a due date.
    static func dueLabel(for due: Date, now: Date = .now) -> (text: String, tint: Color) {
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: due)
        ).day ?? 0
        switch days {
        case ..<0: return ("\(-days)일 지남", .orange)
        case 0: return ("오늘", ArcaSkins.current.hi)
        case 1: return ("내일", ArcaSkins.current.hi)
        default: return ("D-\(days)", .secondary)
        }
    }

    // MARK: - Sweep

    /// How long an untouched AI suggestion stays before it's auto-retired.
    static let staleAfter: TimeInterval = 72 * 3600
    private static let sweepEvery: TimeInterval = 6 * 3600

    /// Runs at most every 6h (piggybacks the Mac heartbeat): trashes stale AI
    /// suggestions and duplicate harvests. Human-entered tasks are NEVER
    /// touched. Trashing (not deleting) keeps relay-merge tombstones intact.
    @MainActor
    static func sweepIfDue(context: ModelContext, now: Date = .now) {
        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: "todoTriageLastSweep")
        guard now.timeIntervalSince1970 - last > sweepEvery else { return }
        defaults.set(now.timeIntervalSince1970, forKey: "todoTriageLastSweep")

        let open = (try? context.fetch(FetchDescriptor<TodoTask>(
            predicate: #Predicate { $0.stateRaw == "open" }
        ))) ?? []

        var retired = 0
        var seenTitles: [String: TodoTask] = [:]
        for task in open.sorted(by: { $0.createdAt > $1.createdAt }) {
            guard !isHuman(task) else { continue }

            // Same harvest surfacing twice (e.g. two CI-failure emails about
            // the same broken deploy) — keep the newest only.
            let key = normalizedTitle(task.title)
            if seenTitles[key] != nil {
                retire(task, reason: "중복 제안이라 자동 정리했어요")
                retired += 1
                continue
            }
            seenTitles[key] = task

            if now.timeIntervalSince(task.updatedAt) > staleAfter {
                retire(task, reason: "3일간 손대지 않아 자동 정리했어요 — 필요하면 다시 맡겨 주세요")
                retired += 1
            }
        }
        if retired > 0 {
            try? context.save()
            DebugTrace.log("todo triage: retired \(retired) stale/duplicate suggestions")
        }
    }

    private static func retire(_ task: TodoTask, reason: String) {
        task.state = .trashed
        task.resultMarkdown = reason
        task.touch()
    }

    /// "Fix failed GitHub Actions deploy (dbc277f)" → "fix failed github actions deploy"
    static func normalizedTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
