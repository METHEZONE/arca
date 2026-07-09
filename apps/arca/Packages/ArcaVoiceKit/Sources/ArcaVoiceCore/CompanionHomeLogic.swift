import Foundation

public enum CompanionHomeLogic {
    public static func conversationTitle(firstUserText: String?,
                                         fallbackText: String?,
                                         maxCharacters: Int = 28) -> String {
        let source = [firstUserText, fallbackText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "새 대화"
        return clipped(source, maxCharacters: maxCharacters)
    }

    public static func dayCount(since earliest: Date?,
                                now: Date = .now,
                                calendar: Calendar = .current) -> Int {
        guard let earliest else { return 1 }
        let start = calendar.startOfDay(for: earliest)
        let end = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        return max(1, days + 1)
    }

    public static func dailyCacheKey(prefix: String,
                                     date: Date = .now,
                                     calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return "\(prefix).\(String(format: "%04d-%02d-%02d", year, month, day))"
    }

    public static func clipped(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(max(0, maxCharacters - 1))) + "…"
    }
}
