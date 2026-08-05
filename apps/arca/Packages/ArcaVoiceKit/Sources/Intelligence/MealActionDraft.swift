import Foundation

/// A meal ARCA heard the user mention and estimated, emitted as a `[MEAL: {…}]`
/// action tag. Same contract as the calendar and email drafts: the model states
/// the action inline, the app executes it — no confirmation round-trip, because
/// "밥 먹었어, 김치찌개" followed by "정말 기록할까요?" is the failure mode.
public struct MealActionDraft: Codable, Sendable, Equatable {
    public var label: String
    public var calories: Double
    public var proteinGrams: Double?
    public var carbsGrams: Double?
    public var fatGrams: Double?
    /// `YYYY-MM-DDTHH:MM` local time. Omitted means now.
    public var at: String?
    public var note: String?

    public init(label: String, calories: Double,
                proteinGrams: Double? = nil, carbsGrams: Double? = nil, fatGrams: Double? = nil,
                at: String? = nil, note: String? = nil) {
        self.label = label
        self.calories = calories
        self.proteinGrams = proteinGrams
        self.carbsGrams = carbsGrams
        self.fatGrams = fatGrams
        self.at = at
        self.note = note
    }

    /// When the meal happened. An unparseable or absent timestamp means now —
    /// the user is almost always logging something they just ate.
    public func date(now: Date = .now, calendar: Calendar = .current) -> Date {
        guard let at, !at.isEmpty else { return now }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone

        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "HH:mm"] {
            formatter.dateFormat = format
            guard let parsed = formatter.date(from: at) else { continue }
            guard format == "HH:mm" else { return parsed }
            // A bare time means today at that time.
            let time = calendar.dateComponents([.hour, .minute], from: parsed)
            return calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0,
                                 second: 0, of: now) ?? now
        }
        return now
    }

    /// Rejects drafts with nothing worth recording.
    public var isUsable: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (calories > 0 || proteinGrams != nil || carbsGrams != nil || fatGrams != nil)
    }
}
