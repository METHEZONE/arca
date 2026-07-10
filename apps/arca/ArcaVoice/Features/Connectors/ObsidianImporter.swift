import Foundation
import SwiftData
import ArcaVoiceKit

enum ObsidianImporter {
    @MainActor
    static func importVault(from vaultURL: URL, context: ModelContext) throws -> (imported: Int, skipped: Int) {
        guard directoryExists(at: vaultURL) else {
            throw ObsidianExportError.missingVault
        }

        let files = try markdownFiles(in: vaultURL)
            .sorted { $0.modificationDate > $1.modificationDate }
            .prefix(200)

        let existingFacts = try context.fetch(FetchDescriptor<MemoryFact>())
        var importedTitlePrefixes = Set(
            existingFacts
                .filter { $0.sourceRaw == "obsidian" }
                .compactMap { titlePrefix(from: $0.text) }
        )

        var imported = 0
        var skipped = 0

        for file in files {
            let title = file.url.deletingPathExtension().lastPathComponent
            let titlePrefix = "「\(title)」"

            guard !importedTitlePrefixes.contains(titlePrefix) else {
                skipped += 1
                continue
            }

            let markdown = try String(contentsOf: file.url, encoding: .utf8)
            let preview = ObsidianNoteText.preview(from: markdown)
            let text = preview.isEmpty ? titlePrefix : "\(titlePrefix) \(preview)"
            context.insert(MemoryFact(text: text, kind: "fact", source: "obsidian"))
            importedTitlePrefixes.insert(titlePrefix)
            imported += 1
        }

        try context.save()
        return (imported, skipped)
    }

    private static func markdownFiles(in vaultURL: URL) throws -> [VaultMarkdownFile] {
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        var files: [VaultMarkdownFile] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: resourceKeys)
            if values.isDirectory == true {
                if shouldSkipDirectory(url, vaultURL: vaultURL) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard url.pathExtension.lowercased() == "md",
                  !isInsideSkippedDirectory(url, vaultURL: vaultURL) else {
                continue
            }

            files.append(VaultMarkdownFile(
                url: url,
                modificationDate: values.contentModificationDate ?? .distantPast
            ))
        }

        return files
    }

    private static func shouldSkipDirectory(_ url: URL, vaultURL: URL) -> Bool {
        let name = url.lastPathComponent
        return name == "ARCA" || name.hasPrefix(".") || isInsideSkippedDirectory(url, vaultURL: vaultURL)
    }

    private static func isInsideSkippedDirectory(_ url: URL, vaultURL: URL) -> Bool {
        let relativeComponents = Array(url.standardizedFileURL.pathComponents.dropFirst(vaultURL.standardizedFileURL.pathComponents.count))
        return relativeComponents.contains { component in
            component == "ARCA" || component.hasPrefix(".")
        }
    }

    private static func titlePrefix(from text: String) -> String? {
        guard text.hasPrefix("「"),
              let end = text.firstIndex(of: "」") else {
            return nil
        }
        return String(text[...end])
    }

    private static func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

private struct VaultMarkdownFile {
    let url: URL
    let modificationDate: Date
}
