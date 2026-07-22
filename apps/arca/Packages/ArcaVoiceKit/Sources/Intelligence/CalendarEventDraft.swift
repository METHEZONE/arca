import Foundation

/// A calendar event the chat model asked ARCA to create via a
/// `[CALENDAR: {…}]` action tag. Mirrors the JSON shape promised in
/// `ClaudeChat.systemPrompt`.
public struct CalendarEventDraft: Codable, Equatable, Sendable {
    public var title: String
    /// Naive local wall-clock start, "yyyy-MM-dd'T'HH:mm" (seconds optional).
    public var start: String
    public var durationMinutes: Int?
    public var location: String?
    public var description: String?

    public init(title: String, start: String, durationMinutes: Int? = nil,
                location: String? = nil, description: String? = nil) {
        self.title = title
        self.start = start
        self.durationMinutes = durationMinutes
        self.location = location
        self.description = description
    }

    /// `start` parsed in the user's current time zone; nil when malformed.
    public var startDate: Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: start) { return date }
        }
        return nil
    }
}
