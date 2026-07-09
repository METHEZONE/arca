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
