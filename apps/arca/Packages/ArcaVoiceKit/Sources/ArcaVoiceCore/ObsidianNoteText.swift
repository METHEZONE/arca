import Foundation

public enum ObsidianNoteText {
    public static func removingYAMLFrontmatter(from markdown: String) -> String {
        guard markdown.hasPrefix("---") else { return markdown }

        let scalars = markdown.unicodeScalars
        var index = scalars.index(scalars.startIndex, offsetBy: 3)
        guard index < scalars.endIndex,
              isNewline(scalars[index]) else {
            return markdown
        }

        while index < scalars.endIndex {
            let lineStart = scalars.index(after: index)
            guard lineStart < scalars.endIndex else { return "" }
            var lineEnd = lineStart
            while lineEnd < scalars.endIndex, !isNewline(scalars[lineEnd]) {
                lineEnd = scalars.index(after: lineEnd)
            }

            let line = String(scalars[lineStart..<lineEnd]).trimmingCharacters(in: .whitespaces)
            if line == "---" || line == "..." {
                let bodyStart = lineEnd < scalars.endIndex ? scalars.index(after: lineEnd) : scalars.endIndex
                return String(scalars[bodyStart...]).trimmingCharacters(in: .newlines)
            }

            index = lineEnd
        }

        return markdown
    }

    private static func isNewline(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.newlines.contains(scalar)
    }

    public static func preview(from markdown: String, limit: Int = 240) -> String {
        let body = removingYAMLFrontmatter(from: markdown)
        let collapsed = body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
