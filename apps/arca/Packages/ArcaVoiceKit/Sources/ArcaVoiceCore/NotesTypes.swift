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
        public var todoTaskUID: String?
        public var calendarEventID: String?

        public var isLinked: Bool {
            todoTaskUID != nil || calendarEventID != nil
        }

        public init(id: UUID? = nil, text: String, assigneeName: String? = nil, due: Date? = nil,
                    todoTaskUID: String? = nil, calendarEventID: String? = nil) {
            self.id = id
            self.text = text
            self.assigneeName = assigneeName
            self.due = due
            self.todoTaskUID = todoTaskUID
            self.calendarEventID = calendarEventID
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
