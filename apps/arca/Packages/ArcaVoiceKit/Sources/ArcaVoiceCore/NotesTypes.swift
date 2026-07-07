import Foundation

public enum NoteStyle: String, Codable, Sendable, CaseIterable {
    case meetingSummary
    case enhancedNotes   // Granola-style: user's rough notes completed with transcript context
    case actionItems
}

public struct MeetingNotes: Sendable, Codable {
    public struct ActionItem: Sendable, Codable {
        public var text: String
        public var assigneeName: String?
        public var due: Date?

        public init(text: String, assigneeName: String? = nil, due: Date? = nil) {
            self.text = text
            self.assigneeName = assigneeName
            self.due = due
        }
    }

    public var title: String
    public var summaryMarkdown: String
    public var decisions: [String]
    public var actionItems: [ActionItem]
    /// The user's rough notes, rewritten/completed using transcript context.
    public var enhancedNotesMarkdown: String?

    public init(title: String, summaryMarkdown: String, decisions: [String] = [],
                actionItems: [ActionItem] = [], enhancedNotesMarkdown: String? = nil) {
        self.title = title
        self.summaryMarkdown = summaryMarkdown
        self.decisions = decisions
        self.actionItems = actionItems
        self.enhancedNotesMarkdown = enhancedNotesMarkdown
    }
}
