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
        let content = noteContent(for: session, note: note, summary: summary)
        let url = arcaDirectory.appendingPathComponent(MeetingNoteMarkdown.fileName(for: content))
        try MeetingNoteMarkdown.vaultNote(content)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The vault note, the clipboard and the nightly digest all render from this
    /// one description, so they can't drift into three different documents.
    static func noteContent(for session: RecordingSession,
                            note: SessionNote,
                            summary: String) -> MeetingNoteMarkdown.Content {
        MeetingNoteMarkdown.Content(
            title: session.title,
            date: session.createdAt,
            summary: summary,
            decisions: MeetingNoteMarkdown.decodeDecisions(from: note.decisionsJSON),
            actionItems: MeetingNoteMarkdown.decodeActionItems(from: note.actionItemsJSON),
            durationSeconds: session.duration)
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

    private static func dayString(from date: Date) -> String {
        MeetingNoteMarkdown.dayString(from: date)
    }
}

private extension FileManager {
    func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
