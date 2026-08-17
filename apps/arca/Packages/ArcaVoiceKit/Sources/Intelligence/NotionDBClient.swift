import Foundation
import ArcaVoiceCore

public enum NotionAPIError: Error, LocalizedError, Equatable {
    case notConfigured
    case badDatabaseReference(String)
    case http(Int, String)
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Notion 토큰이 없어요 — ~/.arca/connections.json 의 notionToken 을 채워주세요."
        case .badDatabaseReference(let value):
            return "Notion 데이터베이스 주소를 읽지 못했어요: \(value)"
        case .http(let status, let message):
            return "Notion API \(status): \(message)"
        case .malformedResponse(let detail):
            return "Notion 응답을 해석하지 못했어요: \(detail)"
        }
    }
}

/// Talks to the Notion REST API directly rather than through Composio's tool
/// wrappers.
///
/// The wrappers flatten Notion's per-kind property payloads, which is exactly
/// the part this feature needs precise control over — a `status` column and a
/// `select` column look identical through a generic "update row" tool and
/// silently no-op when the shape is wrong. The web app's
/// `lib/integrations/notion.ts` already speaks this API, so app and web now
/// share one integration surface. Composio keeps Gmail/Slack/Calendar, where the
/// value it adds is OAuth token custody.
///
/// `Notion-Version` is pinned to 2022-06-28 on purpose. Version 2025-09-03 moved
/// database queries to `/v1/data_sources/{id}/query` and made database ids and
/// data-source ids non-interchangeable; 2022-06-28 keeps `/v1/databases/{id}/query`
/// working for single-data-source databases, which is every database made in the
/// Notion UI. Upgrading is a separate migration, not a prerequisite here.
public struct NotionDBClient: Sendable {
    public static let apiVersion = "2022-06-28"

    private let token: String
    private let session: URLSession

    public init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    /// Builds a client from ~/.arca/connections.json; nil when no token is set.
    public static func fromArcaConfig() -> NotionDBClient? {
        guard let token = ArcaConfig.loadConnections()?.notionToken,
              !token.isEmpty else { return nil }
        return NotionDBClient(token: token)
    }

    // MARK: - Database reference parsing

    /// Pulls the 32-hex id out of whatever the user pasted: a bare id, a dashed
    /// id, or a full `notion.so/workspace/Title-<id>?v=<viewId>` URL. The view
    /// id in the query string is deliberately not a candidate — picking it up
    /// produces a confusing "database not found" much later.
    public static func databaseId(from reference: String) throws -> String {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NotionAPIError.badDatabaseReference(reference) }

        // Drop the query string first so `?v=` view ids can never win.
        let withoutQuery = trimmed.split(separator: "?").first.map(String.init) ?? trimmed
        let candidates = withoutQuery.matches(of: /[0-9a-fA-F]{32}/).map { String($0.output) }
        if let last = candidates.last { return last }

        // Dashed UUID form.
        let dashed = withoutQuery.matches(of: /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/)
        if let match = dashed.last {
            return String(match.output).replacingOccurrences(of: "-", with: "")
        }
        throw NotionAPIError.badDatabaseReference(reference)
    }

    // MARK: - Schema

    public func fetchSchema(databaseId: String) async throws -> NotionDatabaseSchema {
        let json = try await send(method: "GET", path: "databases/\(databaseId)", body: nil)
        guard let schema = NotionDatabaseSchema.decode(from: json) else {
            throw NotionAPIError.malformedResponse("database \(databaseId) had no id/properties")
        }
        return schema
    }

    // MARK: - Rows

    public struct Row: Sendable, Equatable {
        public let id: String
        /// The title-column text — 업체명 for the OEM tracker.
        public let title: String
        /// Existing writable values, keyed by column name. Empty columns are absent.
        public let values: [String: String]
        public let lastEditedAt: Date?
        public let createdAt: Date?
    }

    /// Every row in the database, following pagination up to `pageLimit` pages.
    /// The cap exists so a runaway database cannot stall a post-meeting sync;
    /// `truncated` says whether rows were left unread so the caller can say so
    /// instead of silently matching against a partial list.
    public func fetchRows(databaseId: String, pageLimit: Int = 5)
        async throws -> (rows: [Row], truncated: Bool) {
        var rows: [Row] = []
        var cursor: String?
        var pages = 0

        repeat {
            var body: [String: Any] = ["page_size": 100]
            if let cursor { body["start_cursor"] = cursor }
            let json = try await send(method: "POST",
                                     path: "databases/\(databaseId)/query", body: body)
            guard let results = json["results"] as? [[String: Any]] else {
                throw NotionAPIError.malformedResponse("query returned no results array")
            }
            rows.append(contentsOf: results.compactMap(Self.row(from:)))
            cursor = (json["has_more"] as? Bool == true) ? json["next_cursor"] as? String : nil
            pages += 1
        } while cursor != nil && pages < pageLimit

        return (rows, cursor != nil)
    }

    static func row(from page: [String: Any]) -> Row? {
        guard let id = page["id"] as? String else { return nil }
        let values = NotionPropertyReader.values(from: page)
        var title = ""
        if let properties = page["properties"] as? [String: Any] {
            for (_, property) in properties {
                guard let property = property as? [String: Any],
                      property["type"] as? String == "title" else { continue }
                title = NotionDatabaseSchema.plainText(from: property["title"])
                break
            }
        }
        let parse = { (key: String) -> Date? in
            guard let raw = page[key] as? String else { return nil }
            return timestamp(from: raw)
        }
        return Row(id: id, title: title, values: values,
                   lastEditedAt: parse("last_edited_time"), createdAt: parse("created_time"))
    }

    /// Notion stamps timestamps with fractional seconds (`2026-08-14T06:00:00.000Z`),
    /// which a default `ISO8601DateFormatter` rejects outright — so both shapes
    /// are tried rather than silently returning nil.
    static func timestamp(from raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    @discardableResult
    public func updateProperties(pageId: String,
                                 properties: [String: Any]) async throws -> [String: Any] {
        guard !properties.isEmpty else { return [:] }
        return try await send(method: "PATCH", path: "pages/\(pageId)",
                              body: ["properties": properties])
    }

    /// Creates a row. Used only when no existing row matches — the common path
    /// updates a row the user already made.
    public func createRow(databaseId: String,
                          properties: [String: Any]) async throws -> String {
        let json = try await send(method: "POST", path: "pages", body: [
            "parent": ["database_id": databaseId],
            "properties": properties,
        ])
        guard let id = json["id"] as? String else {
            throw NotionAPIError.malformedResponse("created page had no id")
        }
        return id
    }

    // MARK: - Blocks

    public struct Block: Sendable, Equatable {
        public let id: String
        public let type: String
        public let text: String
        public let hasChildren: Bool
    }

    public func children(of blockId: String) async throws -> [Block] {
        let json = try await send(method: "GET",
                                 path: "blocks/\(blockId)/children?page_size=100", body: nil)
        guard let results = json["results"] as? [[String: Any]] else {
            throw NotionAPIError.malformedResponse("children returned no results array")
        }
        return results.compactMap { block in
            guard let id = block["id"] as? String,
                  let type = block["type"] as? String else { return nil }
            let body = block[type] as? [String: Any]
            return Block(id: id, type: type,
                         text: NotionDatabaseSchema.plainText(from: body?["rich_text"]),
                         hasChildren: block["has_children"] as? Bool ?? false)
        }
    }

    @discardableResult
    public func appendChildren(to blockId: String,
                               blocks: [[String: Any]]) async throws -> [String] {
        guard !blocks.isEmpty else { return [] }
        var created: [String] = []
        // Notion accepts at most 100 children per append.
        for batch in blocks.chunked(into: 100) {
            let json = try await send(method: "PATCH", path: "blocks/\(blockId)/children",
                                     body: ["children": batch])
            let results = json["results"] as? [[String: Any]] ?? []
            created.append(contentsOf: results.compactMap { $0["id"] as? String })
        }
        return created
    }

    /// Archives a block. Notion has no "replace children" call, so refreshing an
    /// ARCA-owned section means deleting its children and appending the new ones.
    public func deleteBlock(id: String) async throws {
        _ = try await send(method: "DELETE", path: "blocks/\(id)", body: nil)
    }

    /// Swaps the children of a block ARCA owns. Only ever called on a block ARCA
    /// created — the user's own blocks are never touched.
    public func replaceChildren(of blockId: String,
                                with blocks: [[String: Any]]) async throws {
        for existing in try await children(of: blockId) {
            try await deleteBlock(id: existing.id)
        }
        try await appendChildren(to: blockId, blocks: blocks)
    }

    // MARK: - Transport

    private func send(method: String, path: String,
                      body: [String: Any]?) async throws -> [String: Any] {
        guard !token.isEmpty else { throw NotionAPIError.notConfigured }
        guard let url = URL(string: "https://api.notion.com/v1/\(path)") else {
            throw NotionAPIError.malformedResponse("bad path \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response): (Data, URLResponse)
        if let body {
            let payload = try JSONSerialization.data(withJSONObject: body)
            (data, response) = try await uploadBody(session, for: request, body: payload)
        } else {
            (data, response) = try await session.data(for: request)
        }

        guard let http = response as? HTTPURLResponse else {
            throw NotionAPIError.malformedResponse("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            var message = String(data: data, encoding: .utf8) ?? ""
            // Notion puts the useful part in `message`; the raw body is mostly noise.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let apiMessage = json["message"] as? String {
                message = apiMessage
            }
            throw NotionAPIError.http(http.statusCode, String(message.prefix(300)))
        }
        // DELETE and some PATCHes return a body we don't need; an empty object
        // is a success, not a parse failure.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, count > size else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
