import Foundation
import ArcaVoiceCore

public struct CalendarAttendeeInfo: Sendable, Codable, Equatable, Hashable {
    public var email: String
    public var displayName: String?

    public init(email: String, displayName: String? = nil) {
        self.email = email
        self.displayName = displayName
    }
}

public struct CalendarEventInfo: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var attendees: [CalendarAttendeeInfo]

    public init(id: String = UUID().uuidString, title: String, start: Date, end: Date,
                attendees: [CalendarAttendeeInfo] = []) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
    }
}

public enum CalendarOverlapScorer {
    public static func overlapSeconds(event: CalendarEventInfo, start: Date, end: Date) -> TimeInterval {
        let lower = max(event.start.timeIntervalSinceReferenceDate, start.timeIntervalSinceReferenceDate)
        let upper = min(event.end.timeIntervalSinceReferenceDate, end.timeIntervalSinceReferenceDate)
        return max(0, upper - lower)
    }

    public static func bestEvent(overlapping events: [CalendarEventInfo],
                                 start: Date,
                                 end: Date) -> CalendarEventInfo? {
        events
            .map { ($0, overlapSeconds(event: $0, start: start, end: end)) }
            .filter { $0.1 > 0 }
            .max { lhs, rhs in
                if lhs.1 == rhs.1 { return lhs.0.start > rhs.0.start }
                return lhs.1 < rhs.1
            }?
            .0
    }
}

/// Reads Google Calendar events through the Composio connection in
/// ~/.arca/connections.json. GOOGLECALENDAR_EVENTS_LIST was runtime-verified
/// via GET /api/v3/tools/GOOGLECALENDAR_EVENTS_LIST: its arguments use Google
/// API-style camelCase names including calendarId, timeMin, timeMax, timeZone,
/// singleEvents, orderBy, maxResults, and maxAttendees.
public struct ComposioCalendarReader: Sendable {
    private let apiKey: String
    private let userId: String
    private let connectedAccountId: String
    private let endpoint = URL(string: "https://backend.composio.dev/api/v3/tools/execute/GOOGLECALENDAR_EVENTS_LIST")!

    public init(apiKey: String, userId: String, connectedAccountId: String) {
        self.apiKey = apiKey
        self.userId = userId
        self.connectedAccountId = connectedAccountId
    }

    public static func fromArcaConfig() -> ComposioCalendarReader? {
        guard let connections = ArcaConfig.loadConnections(),
              let apiKey = connections.composioApiKey, !apiKey.isEmpty,
              let calendarAccount = connections.connectedAccounts?["GOOGLECALENDAR"],
              !calendarAccount.isEmpty else {
            return nil
        }
        return ComposioCalendarReader(apiKey: apiKey, userId: connections.userId,
                                      connectedAccountId: calendarAccount)
    }

    public func eventsOverlapping(start: Date, end: Date) async throws -> [CalendarEventInfo] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "connected_account_id": connectedAccountId,
            "user_id": userId,
            "arguments": [
                "calendarId": "primary",
                "timeMin": formatter.string(from: start),
                "timeMax": formatter.string(from: end),
                "timeZone": TimeZone.current.identifier,
                "singleEvents": true,
                "orderBy": "startTime",
                "maxResults": 20,
                "maxAttendees": 50,
            ] as [String: Any],
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await uploadBody(URLSession.shared, for: request, body: payload)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw CalendarReaderError.http((response as? HTTPURLResponse)?.statusCode ?? 0,
                                           String(message.prefix(300)))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CalendarReaderError.tool("malformed response")
        }
        if let successful = json["successful"] as? Bool, successful == false {
            let message = ((json["error"] as? [String: Any])?["message"] as? String)
                ?? (json["error"] as? String) ?? "tool error"
            throw CalendarReaderError.tool(message)
        }

        let events = Self.events(from: json)
        return events.filter { CalendarOverlapScorer.overlapSeconds(event: $0, start: start, end: end) > 0 }
    }

    static func events(from json: [String: Any]) -> [CalendarEventInfo] {
        let items = ((json["data"] as? [String: Any])?["items"] as? [[String: Any]])
            ?? ((json["data"] as? [String: Any])?["response_data"] as? [String: Any])?["items"] as? [[String: Any]]
            ?? (json["items"] as? [[String: Any]])
            ?? []
        return items.compactMap(event(from:))
    }

    private static func event(from item: [String: Any]) -> CalendarEventInfo? {
        guard let start = date(from: item["start"] as? [String: Any], isEnd: false),
              let end = date(from: item["end"] as? [String: Any], isEnd: true) else {
            return nil
        }
        let attendees = (item["attendees"] as? [[String: Any]] ?? []).compactMap { attendee -> CalendarAttendeeInfo? in
            guard let email = (attendee["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !email.isEmpty else { return nil }
            let displayName = (attendee["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return CalendarAttendeeInfo(email: email, displayName: displayName?.isEmpty == false ? displayName : nil)
        }
        return CalendarEventInfo(
            id: (item["id"] as? String) ?? UUID().uuidString,
            title: (item["summary"] as? String) ?? "Calendar event",
            start: start,
            end: end,
            attendees: attendees
        )
    }

    private static func date(from object: [String: Any]?, isEnd: Bool) -> Date? {
        guard let object else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = object["dateTime"] as? String {
            return iso.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        }
        if let value = object["date"] as? String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            guard let day = formatter.date(from: value) else { return nil }
            return isEnd ? day : day
        }
        return nil
    }

    public enum CalendarReaderError: Error, LocalizedError {
        case http(Int, String)
        case tool(String)

        public var errorDescription: String? {
            switch self {
            case .http(let status, let body): return "Calendar lookup failed (HTTP \(status)): \(body)"
            case .tool(let message): return "Calendar lookup failed: \(message)"
            }
        }
    }
}
