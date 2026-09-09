import Foundation

public enum NoteStyle: String, Codable, Sendable, CaseIterable {
    case meetingSummary
    case enhancedNotes   // Granola-style: user's rough notes completed with transcript context
    case actionItems
}

public struct MeetingNotes: Sendable, Codable {
    public struct ActionItem: Sendable, Codable {
        public var id: UUID?
        public var text: String
        public var assigneeName: String?
        public var due: Date?
        /// The deadline exactly as it was stated when it isn't a calendar date
        /// ("다음 주 화요일", "이번 분기 안", "미정"). `due` only survives an ISO
        /// date, so without this a stated-but-unparseable deadline vanished.
        public var dueText: String?
        public var todoTaskUID: String?
        public var calendarEventID: String?

        public var isLinked: Bool {
            todoTaskUID != nil || calendarEventID != nil
        }

        /// What to print for the deadline — never blank, so a dropped deadline
        /// reads as "미정" instead of silently disappearing.
        public var dueDisplay: String {
            if let due {
                return due.formatted(date: .numeric, time: .omitted)
            }
            if let dueText, !dueText.isEmpty { return dueText }
            return "미정"
        }

        public init(id: UUID? = nil, text: String, assigneeName: String? = nil, due: Date? = nil,
                    dueText: String? = nil, todoTaskUID: String? = nil, calendarEventID: String? = nil) {
            self.id = id
            self.text = text
            self.assigneeName = assigneeName
            self.due = due
            self.dueText = dueText
            self.todoTaskUID = todoTaskUID
            self.calendarEventID = calendarEventID
        }
    }

    /// One discussed subject, anchored to where it happened in the recording.
    public struct Topic: Sendable, Codable, Equatable {
        public var title: String
        /// Human-readable span from the transcript timestamps, e.g. "00:03:12–00:21:40".
        public var timeRange: String
        public var keyPoints: [String]
        /// Verbatim (or near-verbatim) lines that carry the point.
        public var quotes: [String]

        public init(title: String, timeRange: String = "",
                    keyPoints: [String] = [], quotes: [String] = []) {
            self.title = title
            self.timeRange = timeRange
            self.keyPoints = keyPoints
            self.quotes = quotes
        }
    }

    /// A decision plus the reasoning behind it — "무엇을" without "왜" is what
    /// made the old notes unusable a week later.
    public struct Decision: Sendable, Codable, Equatable {
        public var decision: String
        public var rationale: String?
        public var decidedBy: String?

        public init(decision: String, rationale: String? = nil, decidedBy: String? = nil) {
            self.decision = decision
            self.rationale = rationale
            self.decidedBy = decidedBy
        }

        /// Flattened one-line form. `decisions` stays `[String]` on the wire so
        /// every existing reader (Obsidian export, note cards, Notion sync,
        /// meeting chat) keeps working — they just get a richer line.
        public var line: String {
            var text = decision
            if let rationale, !rationale.isEmpty { text += " — 근거: \(rationale)" }
            if let decidedBy, !decidedBy.isEmpty { text += " (결정: \(decidedBy))" }
            return text
        }
    }

    public var title: String
    public var summaryMarkdown: String
    public var decisions: [String]
    public var actionItems: [ActionItem]
    /// The user's rough notes, rewritten/completed using transcript context.
    public var enhancedNotesMarkdown: String?
    public var topics: [Topic]
    /// Structured form of `decisions`; `decisions` holds the rendered lines.
    public var decisionDetails: [Decision]
    /// Raised but not settled during the meeting.
    public var openQuestions: [String]

    public init(title: String, summaryMarkdown: String, decisions: [String] = [],
                actionItems: [ActionItem] = [], enhancedNotesMarkdown: String? = nil,
                topics: [Topic] = [], decisionDetails: [Decision] = [],
                openQuestions: [String] = []) {
        self.title = title
        self.summaryMarkdown = summaryMarkdown
        self.decisions = decisions
        self.actionItems = actionItems
        self.enhancedNotesMarkdown = enhancedNotesMarkdown
        self.topics = topics
        self.decisionDetails = decisionDetails
        self.openQuestions = openQuestions
    }

    /// Composes the markdown that gets stored as the note's summary.
    ///
    /// The per-topic detail and the open questions ride inside `summaryMarkdown`
    /// rather than in new `SessionNote` columns on purpose: every surface that
    /// already shows a summary (note card, Obsidian export, summary email,
    /// Notion sync, meeting chat) picks the detail up with no migration and no
    /// per-surface change.
    public static func composeSummaryMarkdown(
        overview: String,
        topics: [Topic],
        openQuestions: [String]
    ) -> String {
        var blocks: [String] = []
        let trimmedOverview = overview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOverview.isEmpty { blocks.append(trimmedOverview) }

        let renderedTopics: [String] = topics.compactMap { topic in
            let title = topic.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let points = topic.keyPoints.filter { !$0.isEmpty }
            let quotes = topic.quotes.filter { !$0.isEmpty }
            guard !title.isEmpty || !points.isEmpty else { return nil }

            var lines: [String] = []
            let range = topic.timeRange.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(range.isEmpty ? "**\(title)**" : "**\(range) · \(title)**")
            lines.append(contentsOf: points.map { "- \($0)" })
            lines.append(contentsOf: quotes.map { "> \($0)" })
            return lines.joined(separator: "\n")
        }
        if !renderedTopics.isEmpty {
            blocks.append("## 주제별 상세\n\n" + renderedTopics.joined(separator: "\n\n"))
        }

        let questions = openQuestions.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !questions.isEmpty {
            blocks.append("### 미해결 질문\n" + questions.map { "- \($0)" }.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }
}
