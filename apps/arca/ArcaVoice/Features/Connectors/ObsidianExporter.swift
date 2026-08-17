import Foundation
import SwiftData
import ArcaVoiceKit

enum ObsidianExportError: LocalizedError {
    case missingVault
    case missingSummary

    var errorDescription: String? {
        switch self {
        case .missingVault:
            return "Obsidian 볼트 폴더를 먼저 선택하세요."
        case .missingSummary:
            return "내보낼 회의록 요약이 없습니다."
        }
    }
}

enum ObsidianExporter {
    @discardableResult
    static func exportSession(_ session: RecordingSession, to vaultURL: URL) throws -> URL {
        guard FileManager.default.directoryExists(at: vaultURL) else {
            throw ObsidianExportError.missingVault
        }
        guard let note = session.note,
              let summary = note.summaryMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else {
            throw ObsidianExportError.missingSummary
        }

        let arcaDirectory = vaultURL.appendingPathComponent("ARCA", isDirectory: true)
        try FileManager.default.createDirectory(at: arcaDirectory, withIntermediateDirectories: true)
        let fileName = "\(dayString(from: session.createdAt)) \(slugify(session.title)).md"
        let url = arcaDirectory.appendingPathComponent(fileName)
        try sessionMarkdown(for: session, note: note, summary: summary)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Writes a standalone ARCA-authored note into the vault's `ARCA/` folder —
    /// the same folder session exports land in, so everything ARCA puts in the
    /// vault stays in one place (and stays excluded from the note-matching scan
    /// below). For notes that aren't meetings, e.g. crash reports.
    @discardableResult
    static func writeNote(fileName: String, markdown: String, to vaultURL: URL) throws -> URL {
        guard FileManager.default.directoryExists(at: vaultURL) else {
            throw ObsidianExportError.missingVault
        }
        let arcaDirectory = vaultURL.appendingPathComponent("ARCA", isDirectory: true)
        try FileManager.default.createDirectory(at: arcaDirectory, withIntermediateDirectories: true)
        let url = arcaDirectory.appendingPathComponent(fileName)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func exportAll(to vaultURL: URL, context: ModelContext) throws -> Int {
        guard FileManager.default.directoryExists(at: vaultURL) else {
            throw ObsidianExportError.missingVault
        }

        let arcaDirectory = vaultURL.appendingPathComponent("ARCA", isDirectory: true)
        try FileManager.default.createDirectory(at: arcaDirectory, withIntermediateDirectories: true)

        let facts = try context.fetch(FetchDescriptor<MemoryFact>())
        let sessions = try context.fetch(FetchDescriptor<RecordingSession>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        ))

        let memoriesURL = arcaDirectory.appendingPathComponent("ARCA Memories.md")
        try memoriesMarkdown(for: facts).write(to: memoriesURL, atomically: true, encoding: .utf8)
        var fileCount = 1

        for session in sessions {
            guard let note = session.note,
                  let summary = note.summaryMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !summary.isEmpty else {
                continue
            }
            _ = try exportSession(session, to: vaultURL)
            fileCount += 1
        }

        return fileCount
    }

    /// How close a vault note's own timestamps must sit to the session for it
    /// to count as "the note the user was taking during this meeting."
    private static let matchLookbehind: TimeInterval = 20 * 60       // note created up to 20min before start
    private static let matchLookaheadPastEnd: TimeInterval = 90 * 60 // or touched up to 90min after it ends

    /// Finds the note the user was plausibly writing during this session and
    /// appends ARCA's transcript summary underneath it, so the meeting has one
    /// file instead of the user's notes and ARCA's summary living apart. This
    /// is deterministic time-window matching, not a model call — no note
    /// content is read until a candidate is already chosen.
    ///
    /// Idempotent: re-running for a session that's already attached (e.g. a
    /// retried final pass) is a no-op rather than a duplicate block, detected
    /// by an HTML-comment anchor carrying the session's directory name.
    ///
    /// Falls back to `exportSession`'s standalone note when nothing in the
    /// vault matches, so a session never silently goes unexported just
    /// because there was no note to attach to.
    @discardableResult
    static func exportSessionMatchingNote(_ session: RecordingSession, to vaultURL: URL) throws -> URL {
        guard FileManager.default.directoryExists(at: vaultURL) else {
            throw ObsidianExportError.missingVault
        }
        guard let note = session.note,
              let summary = note.summaryMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else {
            throw ObsidianExportError.missingSummary
        }

        guard let match = findMatchingNote(for: session, in: vaultURL) else {
            return try exportSession(session, to: vaultURL)
        }

        let anchor = "<!-- arca-session:\(session.directoryName) -->"
        let existing = (try? String(contentsOf: match, encoding: .utf8)) ?? ""
        guard !existing.contains(anchor) else { return match }

        let addendum = attachmentMarkdown(for: session, note: note, summary: summary, anchor: anchor)
        let separator = existing.isEmpty || existing.hasSuffix("\n\n") ? "" : existing.hasSuffix("\n") ? "\n" : "\n\n"
        try (existing + separator + addendum).write(to: match, atomically: true, encoding: .utf8)
        return match
    }

    /// Scans the vault (skipping ARCA's own export folder and dotfiles) for
    /// the `.md` file whose creation or last-edit time sits closest to this
    /// session's window, picking the smallest distance among files whose own
    /// lifespan overlaps it at all.
    private static func findMatchingNote(for session: RecordingSession, in vaultURL: URL) -> URL? {
        let windowStart = session.createdAt.addingTimeInterval(-matchLookbehind)
        let windowEnd = session.createdAt.addingTimeInterval(session.duration + matchLookaheadPastEnd)

        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .creationDateKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsPackageDescendants]
        ) else { return nil }

        var best: (url: URL, distance: TimeInterval)?
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: resourceKeys) else { continue }
            if values.isDirectory == true {
                if isSkippedVaultDirectoryName(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard url.pathExtension.lowercased() == "md",
                  !isInsideSkippedVaultDirectory(url, vaultURL: vaultURL) else { continue }

            let created = values.creationDate ?? .distantPast
            let modified = values.contentModificationDate ?? .distantPast
            guard created <= windowEnd, modified >= windowStart else { continue }

            let distance = min(abs(created.timeIntervalSince(session.createdAt)),
                               abs(modified.timeIntervalSince(session.createdAt)))
            if best == nil || distance < best!.distance {
                best = (url, distance)
            }
        }
        return best?.url
    }

    private static func isSkippedVaultDirectoryName(_ name: String) -> Bool {
        name == "ARCA" || name.hasPrefix(".")
    }

    private static func isInsideSkippedVaultDirectory(_ url: URL, vaultURL: URL) -> Bool {
        let relative = Array(url.standardizedFileURL.pathComponents.dropFirst(vaultURL.standardizedFileURL.pathComponents.count))
        return relative.contains { isSkippedVaultDirectoryName($0) }
    }

    private static func attachmentMarkdown(for session: RecordingSession, note: SessionNote,
                                           summary: String, anchor: String) -> String {
        let decisions = decodeDecisions(from: note.decisionsJSON)
        let actionItems = decodeActionItems(from: note.actionItemsJSON)
        var lines: [String] = [
            "---",
            "",
            "## 🎙️ ARCA 전사 요약",
            anchor,
            "*\(timeString(from: session.createdAt)) · \(durationString(session.duration))*",
            "",
            summary,
            "",
        ]
        if !decisions.isEmpty {
            lines.append("### 결정사항")
            lines.append(contentsOf: decisions.map { "- \($0)" })
            lines.append("")
        }
        if !actionItems.isEmpty {
            lines.append("### 액션 아이템")
            lines.append(contentsOf: actionItems.map { "- \($0)" })
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private static func durationString(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)분" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)시간" : "\(hours)시간 \(rest)분"
    }

    private static func memoriesMarkdown(for facts: [MemoryFact]) -> String {
        let grouped = Dictionary(grouping: facts.sorted { $0.createdAt > $1.createdAt }, by: \.kindRaw)
        var lines: [String] = ["# ARCA Memories", ""]
        for kind in grouped.keys.sorted() {
            lines.append("## \(kind)")
            for fact in grouped[kind] ?? [] {
                lines.append("- \(dayString(from: fact.createdAt)) · \(fact.text)")
            }
            lines.append("")
        }
        if grouped.isEmpty {
            lines.append("_아직 내보낼 메모리가 없습니다._")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func sessionMarkdown(for session: RecordingSession,
                                        note: SessionNote,
                                        summary: String) -> String {
        let decisions = decodeDecisions(from: note.decisionsJSON)
        let actionItems = decodeActionItems(from: note.actionItemsJSON)
        var lines: [String] = [
            "---",
            "date: \(isoString(from: session.createdAt))",
            "source: arca",
            "type: meeting",
            "---",
            "",
            "# \(session.title)",
            "",
            "## 요약",
            summary,
            "",
        ]

        if !decisions.isEmpty {
            lines.append("## 결정사항")
            lines.append(contentsOf: decisions.map { "- \($0)" })
            lines.append("")
        }

        if !actionItems.isEmpty {
            lines.append("## 액션 아이템")
            lines.append(contentsOf: actionItems.map { "- \($0)" })
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private static func decodeDecisions(from data: Data?) -> [String] {
        guard let data,
              let decisions = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decisions
    }

    private static func decodeActionItems(from data: Data?) -> [String] {
        guard let data,
              let items = try? JSONDecoder().decode([MeetingNotes.ActionItem].self, from: data) else {
            return []
        }
        return items.map { item in
            if let assignee = item.assigneeName, !assignee.isEmpty {
                return "\(item.text) (@\(assignee))"
            }
            return item.text
        }
    }

    private static func slugify(_ title: String) -> String {
        let cleaned = title
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9가-힣ㄱ-ㅎㅏ-ㅣ]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? "untitled" : cleaned
    }

    private static func dayString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

private extension FileManager {
    func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
