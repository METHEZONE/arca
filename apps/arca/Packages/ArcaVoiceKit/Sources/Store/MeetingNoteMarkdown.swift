import Foundation
import ArcaVoiceCore

/// The one place a meeting note becomes markdown.
///
/// It was private to the Obsidian exporter, which meant the copy button, the
/// nightly digest and the vault export would each have grown their own slightly
/// different version of the same document. One builder, three consumers.
public enum MeetingNoteMarkdown {
    /// Decisions and action items as the store holds them: JSON blobs on the note.
    public struct Content: Equatable, Sendable {
        public var title: String
        public var date: Date
        public var summary: String
        public var decisions: [String]
        public var actionItems: [String]
        /// Where it was captured — "회의", "watchMemo" etc., already display-ready.
        public var sourceLabel: String?
        public var durationSeconds: TimeInterval?

        public init(title: String, date: Date, summary: String,
                    decisions: [String] = [], actionItems: [String] = [],
                    sourceLabel: String? = nil, durationSeconds: TimeInterval? = nil) {
            self.title = title
            self.date = date
            self.summary = summary
            self.decisions = decisions
            self.actionItems = actionItems
            self.sourceLabel = sourceLabel
            self.durationSeconds = durationSeconds
        }
    }

    /// Full note with YAML frontmatter — what lands in the vault.
    ///
    /// Every entry point takes a calendar rather than reaching for
    /// `Calendar.current` internally: the times rendered here are the user's local
    /// times, and a builder that can't be told which calendar to use also can't be
    /// tested for the timezone bugs that produce off-by-a-day notes.
    public static func vaultNote(_ content: Content, calendar: Calendar = .current) -> String {
        var lines: [String] = [
            "---",
            "date: \(isoString(from: content.date))",
            "source: arca",
            "type: meeting",
        ]
        if let sourceLabel = content.sourceLabel {
            lines.append("capture: \(sourceLabel)")
        }
        lines.append("---")
        lines.append("")
        lines.append(contentsOf: bodyLines(content, calendar: calendar))
        return lines.joined(separator: "\n")
    }

    /// Same document without frontmatter — what goes on the clipboard, because
    /// nobody wants `---\ndate: …` pasted into Slack.
    public static func clipboardNote(_ content: Content, calendar: Calendar = .current) -> String {
        bodyLines(content, calendar: calendar)
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
    }

    /// The day-note section for one meeting: a heading one level down, so several
    /// meetings nest under a single daily note.
    public static func digestSection(_ content: Content, calendar: Calendar = .current) -> String {
        var lines = ["## \(timeString(from: content.date, calendar: calendar)) \(content.title)", ""]
        let summary = content.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            lines.append(summary)
            lines.append("")
        }
        if !content.decisions.isEmpty {
            lines.append("**\(L("결정", "Decisions"))**")
            lines.append(contentsOf: content.decisions.map { "- \($0)" })
            lines.append("")
        }
        if !content.actionItems.isEmpty {
            lines.append("**\(L("액션", "Actions"))**")
            lines.append(contentsOf: content.actionItems.map { "- [ ] \($0)" })
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func bodyLines(_ content: Content, calendar: Calendar) -> [String] {
        var lines = ["# \(content.title)", ""]

        var meta: [String] = [dayTimeString(from: content.date, calendar: calendar)]
        if let seconds = content.durationSeconds, seconds >= 60 {
            meta.append(durationLabel(minutes: Int(seconds / 60)))
        }
        if let sourceLabel = content.sourceLabel {
            meta.append(sourceLabel)
        }
        lines.append(meta.joined(separator: " · "))
        lines.append("")

        lines.append("## \(L("요약", "Summary"))")
        lines.append(content.summary.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("")

        if !content.decisions.isEmpty {
            lines.append("## \(L("결정사항", "Decisions"))")
            lines.append(contentsOf: content.decisions.map { "- \($0)" })
            lines.append("")
        }

        if !content.actionItems.isEmpty {
            lines.append("## \(L("액션 아이템", "Action items"))")
            lines.append(contentsOf: content.actionItems.map { "- [ ] \($0)" })
            lines.append("")
        }

        return lines
    }

    // MARK: - Decoding the store's JSON blobs

    public static func decodeDecisions(from data: Data?) -> [String] {
        guard let data,
              let decisions = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return decisions
    }

    /// Action items rendered with their assignee, matching what the app shows.
    public static func decodeActionItems(from data: Data?) -> [String] {
        guard let data,
              let items = try? JSONDecoder().decode([MeetingNotes.ActionItem].self, from: data) else {
            return []
        }
        return items.map { item in
            guard let assignee = item.assigneeName, !assignee.isEmpty else { return item.text }
            return "\(item.text) (@\(assignee))"
        }
    }

    // MARK: - Formatting

    /// A file name that sorts by day and stays stable across re-exports, so a
    /// session is overwritten in place rather than duplicated every night.
    public static func fileName(for content: Content, calendar: Calendar = .current) -> String {
        "\(dayString(from: content.date, calendar: calendar)) \(slugify(content.title)).md"
    }

    public static func slugify(_ title: String) -> String {
        let cleaned = title
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9가-힣ㄱ-ㅎㅏ-ㅣ]+"#, with: "-",
                                  options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? "untitled" : cleaned
    }

    /// Local rather than reaching for `VitalsFormat`: `Store` does not depend on
    /// the `Vitals` target, and a note builder is not worth coupling them over.
    public static func dayString(from date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func durationLabel(minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        if hours == 0 { return L("\(mins)분", "\(mins)m") }
        if mins == 0 { return L("\(hours)시간", "\(hours)h") }
        return L("\(hours)시간 \(mins)분", "\(hours)h \(mins)m")
    }

    static func timeString(from date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    static func dayTimeString(from date: Date, calendar: Calendar = .current) -> String {
        "\(dayString(from: date, calendar: calendar)) \(timeString(from: date, calendar: calendar))"
    }

    static func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
