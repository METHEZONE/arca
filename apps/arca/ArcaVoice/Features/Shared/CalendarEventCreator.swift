import EventKit
import Foundation
import ArcaVoiceKit

/// One door to the user's calendar: the Composio Google Calendar connection
/// when configured (~/.arca/connections.json), the system calendar via
/// EventKit otherwise. Shared by chat calendar actions and action items.
enum CalendarEventCreator {
    @discardableResult
    static func create(title: String, start: Date, durationMinutes: Int = 60,
                       location: String? = nil, description: String = "") async throws -> String {
        if let calendar = ComposioCalendar.fromArcaConfig() {
            return try await calendar.createEvent(
                title: title, date: start, description: description,
                durationMinutes: durationMinutes, location: location)
        }
        let store = EKEventStore()
        let granted = try await store.requestWriteOnlyAccessToEvents()
        guard granted else { throw CalendarCreateError.accessDenied }

        let resolvedStart = ComposioCalendar.eventStart(for: start)
        let event = EKEvent(eventStore: store)
        event.title = title
        event.notes = description.isEmpty ? nil : description
        event.location = location
        event.startDate = resolvedStart
        event.endDate = resolvedStart.addingTimeInterval(TimeInterval(max(durationMinutes, 5) * 60))
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent)
        return event.eventIdentifier ?? UUID().uuidString
    }

    enum CalendarCreateError: LocalizedError {
        case accessDenied

        var errorDescription: String? {
            switch self {
            case .accessDenied: return "Calendar access denied"
            }
        }
    }
}
