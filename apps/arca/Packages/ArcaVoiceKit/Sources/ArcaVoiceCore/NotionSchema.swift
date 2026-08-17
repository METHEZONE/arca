import Foundation

/// The live shape of one Notion database, read from the API instead of being
/// hardcoded — ARCA fills the columns the user actually made.
///
/// A vendor tracker with 업체명/담당자명/Phone/Status and a hiring tracker with
/// entirely different columns both work through the same path: the schema drives
/// the extraction prompt, so adding a column in Notion is all it takes for ARCA
/// to start filling it. Only writable property kinds survive decoding; Notion
/// rejects writes to formula/rollup/created_time and friends, so offering them
/// to the extractor would only invite failed patches.
public struct NotionDatabaseSchema: Sendable, Equatable {
    public struct Property: Sendable, Equatable {
        /// The writable Notion property kinds ARCA knows how to fill. The raw
        /// values are Notion's own `type` strings, so decoding is a lookup.
        public enum Kind: String, Sendable, Equatable, CaseIterable {
            case title
            case richText = "rich_text"
            case phoneNumber = "phone_number"
            case email
            case url
            case number
            case select
            case status
            case multiSelect = "multi_select"
            case date
            case checkbox

            /// What the extractor should put in the string it returns. Doubles
            /// as the per-property instruction in the tool schema.
            public var valueHint: String {
                switch self {
                case .title, .richText: return "plain text"
                case .phoneNumber: return "a phone number, digits and hyphens only (e.g. 010-1234-5678)"
                case .email: return "an email address"
                case .url: return "an absolute http(s) URL"
                case .number: return "a bare number, no units or commas"
                case .select, .status: return "exactly one of the allowed options, copied verbatim"
                case .multiSelect: return "one or more allowed options, comma-separated, each copied verbatim"
                case .date: return "a date as YYYY-MM-DD (add THH:MM when a time was actually stated)"
                case .checkbox: return "true or false"
                }
            }
        }

        public let name: String
        public let kind: Kind
        /// Allowed names for select/status/multi_select. The extractor may only
        /// answer with one of these, so ARCA never invents an option Notion
        /// would reject — the 콜드브루 DB's Status column is exactly this case.
        public let options: [String]

        public init(name: String, kind: Kind, options: [String] = []) {
            self.name = name
            self.kind = kind
            self.options = options
        }
    }

    public let id: String
    public let title: String
    public let properties: [Property]
    /// Property names present in Notion but not writable by ARCA, kept for the
    /// log line so a column that never fills is explainable rather than a mystery.
    public let skippedProperties: [String]

    public init(id: String, title: String, properties: [Property],
                skippedProperties: [String] = []) {
        self.id = id
        self.title = title
        self.properties = properties
        self.skippedProperties = skippedProperties
    }

    /// The title property — the row's name column (업체명 here). Every Notion
    /// database has exactly one.
    public var titleProperty: Property? {
        properties.first { $0.kind == .title }
    }

    public func property(named name: String) -> Property? {
        properties.first { $0.name == name }
    }

    // MARK: - Decoding

    /// Parses `GET /v1/databases/{id}`. JSON-object based rather than `Decodable`
    /// because `properties` is keyed by user-chosen column names.
    public static func decode(from json: [String: Any]) -> NotionDatabaseSchema? {
        guard let id = json["id"] as? String else { return nil }
        let title = plainText(from: json["title"])

        var properties: [Property] = []
        var skipped: [String] = []
        if let raw = json["properties"] as? [String: Any] {
            // Notion hands back an unordered dictionary; sort by name so the
            // extraction prompt (and its cache key) is stable across runs.
            for name in raw.keys.sorted() {
                guard let body = raw[name] as? [String: Any],
                      let type = body["type"] as? String else { continue }
                guard let kind = Property.Kind(rawValue: type) else {
                    skipped.append(name)
                    continue
                }
                properties.append(Property(name: name, kind: kind,
                                           options: optionNames(in: body, type: type)))
            }
        }
        return NotionDatabaseSchema(id: id, title: title,
                                    properties: properties, skippedProperties: skipped)
    }

    private static func optionNames(in body: [String: Any], type: String) -> [String] {
        guard let container = body[type] as? [String: Any],
              let options = container["options"] as? [[String: Any]] else { return [] }
        return options.compactMap { $0["name"] as? String }
    }

    /// Flattens a Notion rich-text array into its plain string.
    public static func plainText(from value: Any?) -> String {
        guard let parts = value as? [[String: Any]] else { return "" }
        return parts.compactMap { $0["plain_text"] as? String }.joined()
    }
}

// MARK: - Writing values back

/// Converts the extractor's plain-string answers into Notion's per-kind property
/// payloads. Coercion lives here alone so a value that cannot be represented is
/// dropped locally instead of failing the whole PATCH: one bad phone number must
/// not cost the rest of the row.
public enum NotionPropertyEncoder {
    /// The `properties` value for one column, or nil when `raw` is empty or
    /// cannot be coerced into `property.kind`.
    public static func payload(for property: NotionDatabaseSchema.Property,
                               raw: String) -> [String: Any]? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        switch property.kind {
        case .title:
            return ["title": richText(value)]
        case .richText:
            return ["rich_text": richText(value)]
        case .phoneNumber:
            return ["phone_number": value]
        case .email:
            guard value.contains("@"), !value.hasPrefix("@"), !value.hasSuffix("@") else { return nil }
            return ["email": value]
        case .url:
            guard value.lowercased().hasPrefix("http://") || value.lowercased().hasPrefix("https://") else { return nil }
            return ["url": value]
        case .number:
            guard let number = number(from: value) else { return nil }
            return ["number": number]
        case .select:
            guard let option = matchedOption(value, in: property.options) else { return nil }
            return ["select": ["name": option]]
        case .status:
            guard let option = matchedOption(value, in: property.options) else { return nil }
            return ["status": ["name": option]]
        case .multiSelect:
            let names = value.split(separator: ",")
                .compactMap { matchedOption(String($0), in: property.options) }
            guard !names.isEmpty else { return nil }
            // Notion rejects duplicates in multi_select.
            var seen = Set<String>()
            let unique = names.filter { seen.insert($0).inserted }
            return ["multi_select": unique.map { ["name": $0] }]
        case .date:
            guard let start = notionDateString(from: value) else { return nil }
            return ["date": ["start": start]]
        case .checkbox:
            guard let flag = boolean(from: value) else { return nil }
            return ["checkbox": flag]
        }
    }

    public static func richText(_ text: String) -> [[String: Any]] {
        // Notion caps a single rich-text run at 2000 characters and 413s the
        // whole request past it, so long prose is split rather than truncated.
        chunks(of: text, limit: 2000).map { ["text": ["content": $0]] }
    }

    static func chunks(of text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var result: [String] = []
        var remaining = Substring(text)
        while !remaining.isEmpty {
            let slice = remaining.prefix(limit)
            result.append(String(slice))
            remaining = remaining.dropFirst(slice.count)
        }
        return result
    }

    /// Matches the model's answer against the column's real options: exact
    /// first, then case/whitespace-insensitive. A near-miss is dropped rather
    /// than guessed — a wrong Status is worse than an empty one.
    static func matchedOption(_ value: String, in options: [String]) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let exact = options.first(where: { $0 == trimmed }) { return exact }
        let folded = trimmed.lowercased()
        return options.first { $0.lowercased() == folded }
    }

    static func number(from value: String) -> Double? {
        let cleaned = value
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Double(cleaned)
    }

    static func boolean(from value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "yes", "y", "1", "예", "네", "o": return true
        case "false", "no", "n", "0", "아니오", "아니요", "x": return false
        default: return nil
        }
    }

    /// Accepts `YYYY-MM-DD` and `YYYY-MM-DDTHH:MM(:SS)` and hands Notion back a
    /// string it accepts verbatim; anything else is dropped.
    static func notionDateString(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil { return trimmed }
        if trimmed.wholeMatch(of: /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?/) != nil { return trimmed }
        if ISO8601DateFormatter().date(from: trimmed) != nil { return trimmed }
        return nil
    }
}

// MARK: - Reading values out

/// Reads the plain-text form of a page's existing property values. ARCA needs
/// this to tell an empty column from a filled one: filled columns are left
/// alone unless the meeting explicitly corrects them.
public enum NotionPropertyReader {
    public static func plainValue(from property: Any?) -> String {
        guard let property = property as? [String: Any],
              let type = property["type"] as? String else { return "" }
        switch type {
        case "title":
            return NotionDatabaseSchema.plainText(from: property["title"])
        case "rich_text":
            return NotionDatabaseSchema.plainText(from: property["rich_text"])
        case "phone_number", "email", "url":
            return property[type] as? String ?? ""
        case "number":
            guard let number = property["number"] as? Double else { return "" }
            return number == number.rounded()
                ? String(Int(number))
                : String(number)
        case "select", "status":
            guard let container = property[type] as? [String: Any] else { return "" }
            return container["name"] as? String ?? ""
        case "multi_select":
            guard let items = property["multi_select"] as? [[String: Any]] else { return "" }
            return items.compactMap { $0["name"] as? String }.joined(separator: ", ")
        case "date":
            guard let container = property["date"] as? [String: Any] else { return "" }
            return container["start"] as? String ?? ""
        case "checkbox":
            guard let flag = property["checkbox"] as? Bool else { return "" }
            return flag ? "true" : "false"
        default:
            return ""
        }
    }

    /// Every writable value on a page, keyed by column name.
    public static func values(from page: [String: Any]) -> [String: String] {
        guard let properties = page["properties"] as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (name, property) in properties {
            let value = plainValue(from: property)
            if !value.isEmpty { result[name] = value }
        }
        return result
    }
}
