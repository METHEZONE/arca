#if os(macOS)
import Foundation
import Observation
import SwiftData
import ArcaVoiceKit

/// The evening pass that makes the day's captures add up.
///
/// Two jobs, and the first one is a bug fix as much as a feature:
///
/// 1. **Backfill.** Per-session Obsidian export lived inside `FinalPassRunner`
///    behind `#if os(macOS)`. Recordings from the Watch and the iPhone are
///    processed *on the phone*, so that branch never ran for them — they synced
///    into the shared library and silently never reached the vault. This sweeps
///    every ready session the Mac has, whichever device recorded it, and exports
///    the ones it hasn't yet.
/// 2. **The day note.** One file per day holding every meeting, plus the part a
///    per-meeting summary structurally cannot produce: what runs across them.
///
/// Runs on the Mac because it's the always-on machine and the only one with the
/// vault on disk. Deliberately independent of the day tracker — that's screen
/// recording, a different thing the user may well want off.
@MainActor
@Observable
final class NightlyDigest {
    static let shared = NightlyDigest()

    private(set) var isRunning = false
    private(set) var lastRunAt: Date?
    private(set) var lastResult: String?
    private(set) var exportedCount = 0

    private(set) var isEnabled = true
    private(set) var hour = 21

    private enum Keys {
        static let enabled = "nightlyObsidianDigest"
        static let hour = "nightlyDigestHour"
        static let lastDay = "nightlyDigestLastDay"
        static let exportedUIDs = "obsidianExportedSessionUIDs"
    }

    private let defaults = UserDefaults.standard

    func refreshSettings() {
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        hour = defaults.object(forKey: Keys.hour) as? Int ?? 21
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.enabled)
        refreshSettings()
    }

    // MARK: - Scheduling

    /// Called from the relay heartbeat. Cheap when there's nothing to do.
    func runIfDue(context: ModelContext, now: Date = .now, calendar: Calendar = .current) async {
        refreshSettings()
        guard isEnabled, !isRunning else { return }

        // The backfill isn't time-gated: a recording that finished on the phone
        // at noon shouldn't wait until 21:00 to reach the vault.
        let exported = exportPending(context: context)
        if exported > 0 {
            exportedCount += exported
            lastResult = L("\(exported)개 회의록을 옵시디언에 새로 내보냈어요.",
                           "Exported \(exported) new note\(exported == 1 ? "" : "s") to Obsidian.")
        }

        let today = MeetingNoteMarkdown.dayString(from: now, calendar: calendar)
        guard defaults.string(forKey: Keys.lastDay) != today,
              calendar.component(.hour, from: now) >= hour else { return }

        await writeDayNote(context: context, now: now, calendar: calendar)
        defaults.set(today, forKey: Keys.lastDay)
    }

    /// Manual trigger — "정리하기" in Settings, and how the user can see it work
    /// without waiting for the evening.
    func runNow(context: ModelContext, now: Date = .now, calendar: Calendar = .current) async {
        guard !isRunning else { return }
        let exported = exportPending(context: context)
        exportedCount += exported
        await writeDayNote(context: context, now: now, calendar: calendar)
    }

    // MARK: - Backfill

    /// Exports every ready session that has a summary and hasn't been written to
    /// the vault yet. Idempotent: the file name is derived from the session's day
    /// and title, so a re-export overwrites in place rather than duplicating.
    @discardableResult
    private func exportPending(context: ModelContext) -> Int {
        guard let vault = vaultURL() else { return 0 }
        var exported = Set(defaults.stringArray(forKey: Keys.exportedUIDs) ?? [])

        let sessions = (try? context.fetch(FetchDescriptor<RecordingSession>())) ?? []
        var count = 0
        for session in sessions {
            guard session.state == .ready,
                  session.source != .dayLog,
                  let summary = session.note?.summaryMarkdown?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !summary.isEmpty,
                  !exported.contains(session.directoryName) else { continue }
            do {
                try ObsidianExporter.exportSession(session, to: vault)
                exported.insert(session.directoryName)
                count += 1
            } catch {
                DebugTrace.log("nightly export failed for \(session.title): \(error.localizedDescription)")
            }
        }
        if count > 0 {
            defaults.set(Array(exported), forKey: Keys.exportedUIDs)
        }
        // The brain as a file, refreshed on the same sweep — Memory/Memories.md.
        if let facts = try? context.fetch(FetchDescriptor<MemoryFact>()), !facts.isEmpty {
            try? ObsidianExporter.exportMemories(facts, arcaDirectory: ArcaVault.arcaFolder())
        }
        return count
    }

    // MARK: - The day note

    private func writeDayNote(context: ModelContext, now: Date, calendar: Calendar) async {
        guard let vault = vaultURL() else {
            lastResult = L("옵시디언 볼트가 연결되지 않았어요 — 설정 → 커넥터에서 폴더를 선택해 주세요.",
                           "No Obsidian vault linked — pick a folder in Settings → Connectors.")
            return
        }

        isRunning = true
        defer {
            isRunning = false
            lastRunAt = .now
        }

        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? now
        let sessions = ((try? context.fetch(FetchDescriptor<RecordingSession>())) ?? [])
            .filter {
                $0.createdAt >= dayStart && $0.createdAt < dayEnd
                    && $0.source != .dayLog && $0.state == .ready
            }
            .sorted { $0.createdAt < $1.createdAt }

        let contents = sessions.compactMap { session -> MeetingNoteMarkdown.Content? in
            guard let note = session.note,
                  let summary = note.summaryMarkdown?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !summary.isEmpty else { return nil }
            return MeetingNoteMarkdown.Content(
                title: session.title,
                date: session.createdAt,
                summary: summary,
                decisions: MeetingNoteMarkdown.decodeDecisions(from: note.decisionsJSON),
                actionItems: MeetingNoteMarkdown.decodeActionItems(from: note.actionItemsJSON),
                sourceLabel: Self.sourceLabel(session.source),
                durationSeconds: session.duration)
        }

        guard !contents.isEmpty else {
            lastResult = L("오늘은 정리할 회의 기록이 없었어요.",
                           "No meeting notes to gather today.")
            return
        }

        let dayLabel = MeetingNoteMarkdown.dayString(from: now, calendar: calendar)
        let sections = contents
            .map { MeetingNoteMarkdown.digestSection($0, calendar: calendar) }
            .joined(separator: "\n")

        // Insights are best-effort: a missing key or a failed call must never cost
        // the user the meeting notes themselves, which are the durable part.
        var insightMarkdown: String?
        if let key = ArcaCloud.anthropicKey, !key.isEmpty {
            let model = defaults.string(forKey: "chatModel") ?? "claude-sonnet-5"
            do {
                let insight = try await DailyInsightGenerator(apiKey: key, model: model)
                    .generate(dayMarkdown: sections,
                              dayLabel: dayLabel,
                              focusLine: focusLine())
                if !insight.isEmpty || !insight.headline.isEmpty {
                    insightMarkdown = DailyInsightGenerator.markdown(insight)
                }
            } catch {
                DebugTrace.log("daily insight failed: \(error.localizedDescription)")
            }
        }

        let note = dayNoteMarkdown(dayLabel: dayLabel, contents: contents,
                                   sections: sections, insight: insightMarkdown)
        do {
            let directory = vault
                .appendingPathComponent("ARCA", isDirectory: true)
                .appendingPathComponent("Daily", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try note.write(to: directory.appendingPathComponent("\(dayLabel).md"),
                           atomically: true, encoding: .utf8)
            lastResult = L("\(dayLabel) 정리를 옵시디언에 저장했어요 — 회의 \(contents.count)개\(insightMarkdown == nil ? " (인사이트는 건너뜀)" : "").",
                           "Saved the \(dayLabel) digest to Obsidian — \(contents.count) meeting\(contents.count == 1 ? "" : "s")\(insightMarkdown == nil ? " (insights skipped)" : "").")
        } catch {
            lastResult = L("옵시디언에 쓰지 못했어요: \(error.localizedDescription)",
                           "Couldn't write to Obsidian: \(error.localizedDescription)")
        }
    }

    private func dayNoteMarkdown(dayLabel: String,
                                 contents: [MeetingNoteMarkdown.Content],
                                 sections: String,
                                 insight: String?) -> String {
        var lines: [String] = [
            "---",
            "date: \(dayLabel)",
            "source: arca",
            "type: daily",
            "---",
            "",
            "# \(dayLabel)",
            "",
        ]

        let totalMinutes = contents.reduce(0) { $0 + Int(($1.durationSeconds ?? 0) / 60) }
        var meta = [L("회의 \(contents.count)개", "\(contents.count) meeting\(contents.count == 1 ? "" : "s")")]
        if totalMinutes > 0 {
            meta.append(L("총 \(totalMinutes)분", "\(totalMinutes) min total"))
        }
        let actionCount = contents.reduce(0) { $0 + $1.actionItems.count }
        if actionCount > 0 {
            meta.append(L("액션 \(actionCount)개", "\(actionCount) action\(actionCount == 1 ? "" : "s")"))
        }
        lines.append(meta.joined(separator: " · "))
        lines.append("")

        if let insight {
            lines.append(insight)
        }

        lines.append("# \(L("오늘의 기록", "Today's records"))")
        lines.append("")
        lines.append(sections)

        // Wiki-links back to the individual notes, so the daily note is an index
        // into the vault rather than a copy of it.
        lines.append("## \(L("개별 회의록", "Individual notes"))")
        for content in contents {
            let name = MeetingNoteMarkdown.fileName(for: content)
                .replacingOccurrences(of: ".md", with: "")
            lines.append("- [[\(name)]]")
        }
        lines.append("")

        return lines.joined(separator: "\n")
    }

    /// A line about how the day felt physically, when the phone has measured it.
    private func focusLine() -> String? {
        let vitals = VitalsEngine.shared
        var parts: [String] = []
        if let readiness = vitals.today?.scores.readiness {
            parts.append("readiness \(readiness)/100")
        }
        if let sleep = vitals.today?.metrics.sleep, sleep.asleepMinutes > 0 {
            parts.append("slept \(sleep.asleepMinutes) minutes")
        }
        let ledger = vitals.ledger.current
        if ledger.zoneMinutes > 0 {
            parts.append("\(ledger.zoneMinutes) minutes of focus, \(ledger.absorbed) interruptions absorbed")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Never nil anymore: without a linked Obsidian vault the notes go to the
    /// default ARCA folder in ~/Documents.
    private func vaultURL() -> URL? {
        ArcaVault.resolvedRoot()
    }

    private static func sourceLabel(_ source: SessionSource) -> String {
        switch source {
        case .macMeeting: return L("맥 회의", "Mac meeting")
        case .voiceMemo: return L("음성 메모", "Voice memo")
        case .watchMemo: return L("워치 메모", "Watch memo")
        case .screenshot: return L("화면 캡처", "Screenshot")
        case .shared: return L("공유", "Shared")
        case .imported: return L("가져옴", "Imported")
        case .dayLog: return L("하루 정리", "Day digest")
        }
    }
}
#endif
