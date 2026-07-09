import Foundation
import ArcaVoiceCore

/// Creates Google Calendar events through the Composio connection stored in
/// ~/.arca/connections.json, matching the summary email sender's transport.
public struct ComposioCalendar: Sendable {
    private let apiKey: String
    private let userId: String
    private let connectedAccountId: String
    private let endpoint = URL(string: "https://backend.composio.dev/api/v3/tools/execute/GOOGLECALENDAR_CREATE_EVENT")!

    public init(apiKey: String, userId: String, connectedAccountId: String) {
        self.apiKey = apiKey
        self.userId = userId
        self.connectedAccountId = connectedAccountId
    }

    /// Builds a calendar client from ~/.arca/connections.json; nil when
    /// Composio or the Google Calendar connection is not configured.
    public static func fromArcaConfig() -> ComposioCalendar? {
        guard let connections = ArcaConfig.loadConnections(),
              let apiKey = connections.composioApiKey, !apiKey.isEmpty,
              let calendarAccount = connections.connectedAccounts?["GOOGLECALENDAR"],
              !calendarAccount.isEmpty else {
            return nil
        }
        return ComposioCalendar(apiKey: apiKey, userId: connections.userId,
                                connectedAccountId: calendarAccount)
    }

    /// Creates a one-hour event. Date-only due dates are scheduled at 09:00 in
    /// the current calendar/time zone.
    public func createEvent(title: String, date: Date, description: String) async throws -> String {
        let start = Self.eventStart(for: date)
        // Composio's GOOGLECALENDAR_CREATE_EVENT schema (verified via
        // GET /api/v3/tools/GOOGLECALENDAR_CREATE_EVENT): snake_case args,
        // naive local start_datetime plus a separate IANA timezone.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "connected_account_id": connectedAccountId,
            "user_id": userId,
            "arguments": [
                "calendar_id": "primary",
                "summary": title,
                "description": description,
                "start_datetime": formatter.string(from: start),
                "timezone": TimeZone.current.identifier,
                "event_duration_hour": 1,
                "event_duration_minutes": 0,
            ] as [String: Any],
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await uploadBody(URLSession.shared, for: request, body: payload)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw CalendarError.http((response as? HTTPURLResponse)?.statusCode ?? 0,
                                     String(message.prefix(300)))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CalendarError.tool("malformed response")
        }
        if let successful = json["successful"] as? Bool, successful == false {
            let message = ((json["error"] as? [String: Any])?["message"] as? String)
                ?? (json["error"] as? String) ?? "tool error"
            throw CalendarError.tool(message)
        }
        if let id = Self.eventID(from: json) {
            return id
        }
        throw CalendarError.tool("created event id missing")
    }

    public static func eventStart(for date: Date, calendar: Calendar = .current) -> Date {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        if (components.hour ?? 0) == 0, (components.minute ?? 0) == 0, (components.second ?? 0) == 0 {
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
        }
        return date
    }

    static func eventID(from json: [String: Any]) -> String? {
        if let id = json["id"] as? String, !id.isEmpty { return id }
        if let data = json["data"] as? [String: Any] {
            if let id = data["id"] as? String, !id.isEmpty { return id }
            if let event = data["event"] as? [String: Any],
               let id = event["id"] as? String, !id.isEmpty { return id }
            if let response = data["response_data"] as? [String: Any],
               let id = response["id"] as? String, !id.isEmpty { return id }
        }
        return nil
    }

    public enum CalendarError: Error, LocalizedError {
        case http(Int, String)
        case tool(String)

        public var errorDescription: String? {
            switch self {
            case .http(let status, let body): return "Calendar event creation failed (HTTP \(status)): \(body)"
            case .tool(let message): return "Calendar event creation failed: \(message)"
            }
        }
    }
}
