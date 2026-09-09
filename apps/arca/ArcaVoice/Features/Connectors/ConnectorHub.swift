import Foundation
import SwiftData
import SwiftUI
import ArcaVoiceKit

/// One normalized item pulled from a connected source — a recent email,
/// calendar event, file, or message. Source of truth for what a "Sync
/// context" pull turns into.
struct ContextItem: Identifiable {
    let id = UUID()
    var title: String
    var body: String
    var source: String
    var date: Date?
}

/// A connector ARCA knows how to show and pull from, whether or not the
/// user has connected it yet. `slug` matches the keys used across the app
/// for Composio toolkits (`ArcaConfig.Connections.connectedAccounts`, e.g.
/// "GMAIL"); `toolkitSlug` is the lowercase slug the Composio API itself
/// uses ("gmail").
struct ConnectorInfo: Identifiable {
    let slug: String
    let displayName: String
    let shortName: String
    let symbol: String
    let toolkitSlug: String
    /// The chip color behind the icon — real logos aren't bundled, so each
    /// service gets its own brand-recognizable color block instead of the
    /// same flat gray square for every row.
    let brandColor: Color

    var id: String { slug }
}

enum ConnectorError: LocalizedError {
    case notConfigured
    case unknownConnector(String)
    case noAuthConfig(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return L("이 기기에는 아직 Composio가 설정되지 않았어요.", "Composio isn't set up on this device yet.")
        case .unknownConnector(let slug):
            return L("알 수 없는 커넥터: \(slug)", "Unknown connector: \(slug)")
        case .noAuthConfig(let name):
            return L("Composio 대시보드에서 \(name) 인증 설정을 먼저 만들어 주세요.",
                     "Create an auth config for \(name) in the Composio dashboard first.")
        case .http(let status, let message):
            return status > 0
                ? L("Composio 요청이 실패했어요 (\(status)): \(message)", "Composio request failed (\(status)): \(message)")
                : message
        }
    }
}

/// Discovers, connects, and pulls context from the user's Composio-connected
/// accounts. Talks to `backend.composio.dev` directly with the project API
/// key — there is no ARCA server in the loop.
///
/// Endpoints (Composio v3 REST, live-verified against the ARCA Composio
/// project):
/// - `GET /connected_accounts?user_ids=` — list this user's connections.
/// - `GET /auth_configs?toolkit_slug=` — find the auth config to connect
///   through (singular query param; the plural form is silently ignored).
/// - `POST /connected_accounts/link` `{auth_config_id, user_id}` — issues an
///   OAuth `redirect_url` for the user to open (Composio-managed auth
///   configs reject the older `POST /connected_accounts` shape outright and
///   name this endpoint in the error).
/// - `POST /tools/execute/{TOOL_SLUG}` — run a single tool call.
@MainActor
@Observable
final class ConnectorHub {
    static let catalog: [ConnectorInfo] = [
        ConnectorInfo(slug: "GMAIL", displayName: "Gmail", shortName: "Gmail",
                     symbol: "envelope.fill", toolkitSlug: "gmail",
                     brandColor: Color(red: 0.92, green: 0.26, blue: 0.21)),
        ConnectorInfo(slug: "GOOGLECALENDAR", displayName: "Google Calendar", shortName: "Calendar",
                     symbol: "calendar", toolkitSlug: "googlecalendar",
                     brandColor: Color(red: 0.26, green: 0.52, blue: 0.96)),
        ConnectorInfo(slug: "GOOGLEDRIVE", displayName: "Google Drive", shortName: "Drive",
                     symbol: "doc.fill", toolkitSlug: "googledrive",
                     brandColor: Color(red: 0.06, green: 0.62, blue: 0.35)),
        ConnectorInfo(slug: "SLACK", displayName: "Slack", shortName: "Slack",
                     symbol: "number", toolkitSlug: "slack",
                     brandColor: Color(red: 0.46, green: 0.20, blue: 0.44)),
        ConnectorInfo(slug: "NOTION", displayName: "Notion", shortName: "Notion",
                     symbol: "note.text", toolkitSlug: "notion",
                     brandColor: Color(white: 0.16)),
        ConnectorInfo(slug: "GITHUB", displayName: "GitHub", shortName: "GitHub",
                     symbol: "chevron.left.forwardslash.chevron.right", toolkitSlug: "github",
                     brandColor: Color(white: 0.12)),
        ConnectorInfo(slug: "LINEAR", displayName: "Linear", shortName: "Linear",
                     symbol: "checklist", toolkitSlug: "linear",
                     brandColor: Color(red: 0.37, green: 0.42, blue: 0.82)),
        ConnectorInfo(slug: "TODOIST", displayName: "Todoist", shortName: "Todoist",
                     symbol: "checkmark.circle.fill", toolkitSlug: "todoist",
                     brandColor: Color(red: 0.89, green: 0.26, blue: 0.20)),
    ]

    /// Catalog slug ("GMAIL") -> connected_account_id ("ca_...") for every
    /// toolkit this user currently has an ACTIVE connection to.
    private(set) var accounts: [String: String] = [:]
    /// Catalog slug -> which account it is, in human terms ("me@thezonebio.com",
    /// "THE ZONE BIO"). The connected_accounts payload carries only an opaque
    /// `ca_…` id and an internal `word_id`, so the identity has to be asked of
    /// each toolkit itself. Absent until `refreshIdentities()` resolves it.
    private(set) var identities: [String: String] = [:]
    private(set) var lastError: String?
    private(set) var lastPullSummary: String = ""

    private let base = ArcaCloud.composioBaseURL

    private var apiKey: String? { ArcaCloud.composioKey }
    /// Never nil: the invite identity when connector calls go through the ARCA
    /// Cloud proxy, else this install's own minted id rather than whatever was
    /// baked into the build.
    private var userId: String? {
        if let id = ArcaCloud.composioUserId, !id.isEmpty { return id }
        return ArcaConfig.composioUserId()
    }

    /// Whether connecting is even possible on this device. Surfaced so the UI can
    /// say "no key" out loud instead of showing Connect buttons that quietly fail.
    var isConfigured: Bool {
        (apiKey?.isEmpty == false) && userId != nil
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    // MARK: - Discovery

    func refresh() async {
        guard let apiKey, let userId else {
            lastError = ConnectorError.notConfigured.errorDescription
            accounts = [:]
            return
        }
        do {
            var request = URLRequest(url: base.appendingPathComponent("connected_accounts")
                .appending(queryItems: [URLQueryItem(name: "user_ids", value: userId)]))
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.checkOK(response, data: data)
            let payload = try Self.decoder.decode(ConnectedAccountsResponse.self, from: data)

            var mapped: [String: String] = [:]
            for item in payload.items where item.status.uppercased() == "ACTIVE" {
                guard let toolkitSlug = item.toolkit?.slug.lowercased(),
                      let info = Self.catalog.first(where: { $0.toolkitSlug == toolkitSlug }) else { continue }
                mapped[info.slug] = item.id
            }
            accounts = mapped
            identities = identities.filter { mapped[$0.key] != nil }
            lastError = nil
            await refreshIdentities()
        } catch {
            lastError = L("커넥터를 불러오지 못했어요: \(UserFacingError.message(for: error))",
                          "Couldn't load connectors: \(UserFacingError.message(for: error))")
        }
    }

    // MARK: - Identity

    /// Asks each connected toolkit who it is signed in as, so the Connectors
    /// screen can say "me@thezonebio.com" instead of a `ca_…` fragment. Best
    /// effort and non-fatal: a toolkit that can't answer simply stays unlabeled,
    /// and one slow toolkit must not hold up the others.
    func refreshIdentities() async {
        guard let apiKey, let userId else { return }
        let connected = accounts
        let resolved = await withTaskGroup(of: (String, String?).self) { group in
            for (slug, account) in connected {
                group.addTask { [weak self] in
                    guard let self else { return (slug, nil) }
                    let label = try? await self.identity(
                        for: slug, account: account, userId: userId, apiKey: apiKey)
                    return (slug, label)
                }
            }
            var found: [String: String] = [:]
            for await (slug, label) in group {
                if let label, !label.isEmpty { found[slug] = label }
            }
            return found
        }
        identities = resolved
    }

    private func identity(for toolkit: String, account: String,
                          userId: String, apiKey: String) async throws -> String? {
        switch toolkit {
        case "GMAIL":
            // GMAIL_GET_PROFILE nests its payload under `response_data`.
            let data = try await executeTool("GMAIL_GET_PROFILE", account: account,
                                             userId: userId, apiKey: apiKey, arguments: [:])
            let profile = (data["response_data"] as? [String: Any]) ?? data
            return profile["emailAddress"] as? String

        case "GOOGLEDRIVE":
            // `user` is only returned when explicitly requested.
            let data = try await executeTool("GOOGLEDRIVE_GET_ABOUT", account: account,
                                             userId: userId, apiKey: apiKey,
                                             arguments: ["fields": "user"])
            guard let user = data["user"] as? [String: Any] else { return nil }
            return (user["emailAddress"] as? String) ?? (user["displayName"] as? String)

        case "SLACK":
            let data = try await executeTool("SLACK_FETCH_TEAM_INFO", account: account,
                                             userId: userId, apiKey: apiKey, arguments: [:])
            guard let team = data["team"] as? [String: Any] else { return nil }
            return (team["name"] as? String) ?? (team["domain"] as? String)

        case "GOOGLECALENDAR":
            let data = try await executeTool("GOOGLECALENDAR_LIST_CALENDARS", account: account,
                                             userId: userId, apiKey: apiKey, arguments: [:])
            guard let calendars = data["calendars"] as? [[String: Any]] else { return nil }
            let primary = calendars.first { $0["primary"] as? Bool == true } ?? calendars.first
            return primary?["id"] as? String

        default:
            return nil
        }
    }

    // MARK: - Connecting

    /// Returns an OAuth redirect URL for `toolkit` (a catalog slug, e.g.
    /// "NOTION") to open in the browser. Requires an existing auth config
    /// for that toolkit in the Composio project.
    func connectURL(for toolkit: String) async throws -> URL {
        guard let apiKey, let userId else { throw ConnectorError.notConfigured }
        guard let info = Self.catalog.first(where: { $0.slug == toolkit }) else {
            throw ConnectorError.unknownConnector(toolkit)
        }

        var authConfigsRequest = URLRequest(url: base.appendingPathComponent("auth_configs")
            .appending(queryItems: [URLQueryItem(name: "toolkit_slug", value: info.toolkitSlug)]))
        authConfigsRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        let (configData, configResponse) = try await URLSession.shared.data(for: authConfigsRequest)
        try Self.checkOK(configResponse, data: configData)
        let configs = try Self.decoder.decode(AuthConfigsResponse.self, from: configData)
        guard let authConfigId = configs.items.first?.id else {
            throw ConnectorError.noAuthConfig(info.displayName)
        }

        var linkRequest = URLRequest(url: base.appendingPathComponent("connected_accounts/link"))
        linkRequest.httpMethod = "POST"
        linkRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        linkRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        let body = ["auth_config_id": authConfigId, "user_id": userId]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await uploadBody(URLSession.shared, for: linkRequest, body: payload)
        try Self.checkOK(response, data: data)
        let link = try Self.decoder.decode(LinkResponse.self, from: data)
        guard let url = URL(string: link.redirectUrl) else {
            throw ConnectorError.http(0, L("Composio가 잘못된 연결 링크를 보냈어요.", "Composio returned an invalid connect link."))
        }
        return url
    }

    // MARK: - Pulling

    /// Fetches a small recent batch from `toolkit` (a catalog slug, e.g.
    /// "GMAIL"). The toolkit must already be connected.
    func pull(from toolkit: String) async throws -> [ContextItem] {
        guard let apiKey, let userId else { throw ConnectorError.notConfigured }
        guard let account = accounts[toolkit] else { throw ConnectorError.unknownConnector(toolkit) }
        switch toolkit {
        case "GMAIL":
            return try await pullGmail(account: account, userId: userId, apiKey: apiKey)
        case "GOOGLECALENDAR":
            return try await pullCalendar(account: account, userId: userId, apiKey: apiKey)
        case "GOOGLEDRIVE":
            return try await pullDrive(account: account, userId: userId, apiKey: apiKey)
        case "SLACK":
            return try await pullSlack(account: account, userId: userId, apiKey: apiKey)
        default:
            return []
        }
    }

    /// Pulls every connected toolkit and inserts each item as a MemoryFact,
    /// skipping any whose text already exists. Updates `lastPullSummary`.
    func pullAllIntoMemory(context: ModelContext) async {
        let connected = Self.catalog.filter { accounts[$0.slug] != nil }
        guard !connected.isEmpty else {
            lastPullSummary = L("아직 가져올 연결된 소스가 없어요.", "No connected sources to pull from yet.")
            return
        }

        var seen = Set(((try? context.fetch(FetchDescriptor<MemoryFact>())) ?? []).map(\.text))
        var counts: [(name: String, count: Int)] = []

        for info in connected {
            do {
                let items = try await pull(from: info.slug)
                let added = Self.insertNewFacts(items, info: info, into: context, seen: &seen)
                if added > 0 { counts.append((info.shortName, added)) }
            } catch {
                lastError = L("\(info.displayName) 가져오기에 실패했어요: \(UserFacingError.message(for: error))",
                              "Pull failed for \(info.displayName): \(UserFacingError.message(for: error))")
            }
        }
        try? context.save()

        lastPullSummary = counts.isEmpty
            ? L("새로 가져올 항목이 없어요.", "Nothing new to pull.")
            : L("\(counts.map { "\($0.count) \($0.name)" }.joined(separator: " · ")) 항목을 가져왔어요",
                "Pulled " + counts.map { "\($0.count) \($0.name)" }.joined(separator: " · ") + " items")
    }

    /// Pulls a single connected toolkit into memory — backs the per-row
    /// "Pull" action in the Connectors screen (as opposed to "Sync context",
    /// which runs every connected toolkit via `pullAllIntoMemory`).
    func pullOneIntoMemory(toolkit: String, context: ModelContext) async {
        guard let info = Self.catalog.first(where: { $0.slug == toolkit }) else { return }
        var seen = Set(((try? context.fetch(FetchDescriptor<MemoryFact>())) ?? []).map(\.text))
        do {
            let items = try await pull(from: toolkit)
            let added = Self.insertNewFacts(items, info: info, into: context, seen: &seen)
            try? context.save()
            lastPullSummary = added > 0
                ? L("\(info.shortName) 항목 \(added)개를 가져왔어요",
                    added == 1 ? "Pulled 1 \(info.shortName) item" : "Pulled \(added) \(info.shortName) items")
                : L("\(info.shortName)에서 새로 가져올 항목이 없어요.", "Nothing new from \(info.shortName).")
        } catch {
            lastError = L("\(info.displayName) 가져오기에 실패했어요: \(UserFacingError.message(for: error))",
                          "Pull failed for \(info.displayName): \(UserFacingError.message(for: error))")
        }
    }

    private static func insertNewFacts(_ items: [ContextItem], info: ConnectorInfo,
                                       into context: ModelContext, seen: inout Set<String>) -> Int {
        var added = 0
        for item in items {
            let body = String(item.body.prefix(120))
            let text = "[\(info.displayName)] \(item.title) — \(body)"
            guard !seen.contains(text) else { continue }
            context.insert(MemoryFact(text: text, kind: "fact", source: info.slug.lowercased()))
            seen.insert(text)
            added += 1
        }
        return added
    }

    // MARK: - Per-connector pulls

    private func pullGmail(account: String, userId: String, apiKey: String) async throws -> [ContextItem] {
        let json = try await executeTool("GMAIL_FETCH_EMAILS", account: account, userId: userId, apiKey: apiKey,
                                         arguments: ["max_results": 8, "query": "newer_than:2d"])
        let messages = (json["messages"] as? [[String: Any]]) ?? []
        let iso = ISO8601DateFormatter()
        return messages.prefix(8).map { message in
            let sender = (message["sender"] as? String) ?? "(Unknown sender)"
            let subject = (message["subject"] as? String) ?? "(No subject)"
            let preview = (message["preview"] as? [String: Any])?["body"] as? String
            let body = preview ?? (message["messageText"] as? String) ?? ""
            let date = (message["messageTimestamp"] as? String).flatMap { iso.date(from: $0) }
            return ContextItem(title: "\(subject) — \(sender)", body: body, source: "gmail", date: date)
        }
    }

    private func pullCalendar(account: String, userId: String, apiKey: String) async throws -> [ContextItem] {
        let iso = ISO8601DateFormatter()
        let now = Date()
        let weekOut = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now
        let json = try await executeTool("GOOGLECALENDAR_EVENTS_LIST", account: account, userId: userId, apiKey: apiKey,
                                         arguments: [
                                            "calendarId": "primary",
                                            "timeMin": iso.string(from: now),
                                            "timeMax": iso.string(from: weekOut),
                                            "maxResults": 8,
                                            "singleEvents": true,
                                            "orderBy": "startTime",
                                         ])
        let items = (json["items"] as? [[String: Any]]) ?? []
        return items.prefix(8).map { event in
            let title = (event["summary"] as? String) ?? "(untitled event)"
            let start = event["start"] as? [String: Any]
            let dateTimeString = start?["dateTime"] as? String
            let dateOnlyString = start?["date"] as? String
            let date = dateTimeString.flatMap { iso.date(from: $0) }
                ?? dateOnlyString.flatMap { Self.dayFormatter.date(from: $0) }
            let when = dateTimeString ?? dateOnlyString ?? "TBD"
            return ContextItem(title: title, body: "Starts \(when)", source: "googlecalendar", date: date)
        }
    }

    private func pullDrive(account: String, userId: String, apiKey: String) async throws -> [ContextItem] {
        let json = try await executeTool("GOOGLEDRIVE_LIST_FILES", account: account, userId: userId, apiKey: apiKey,
                                         arguments: [
                                            "orderBy": "modifiedTime desc",
                                            "pageSize": 8,
                                            "fields": "files(id,name,mimeType,modifiedTime)",
                                         ])
        let files = (json["files"] as? [[String: Any]]) ?? []
        let iso = ISO8601DateFormatter()
        return files.prefix(8).map { file in
            let name = (file["name"] as? String) ?? "(untitled file)"
            let mimeType = (file["mimeType"] as? String) ?? ""
            let date = (file["modifiedTime"] as? String).flatMap { iso.date(from: $0) }
            return ContextItem(title: name, body: mimeType, source: "googledrive", date: date)
        }
    }

    /// Slack search is intentionally narrow: only messages likely directed at
    /// the user or carrying an action cue survive the post-filter. This keeps
    /// ARCA's Memory Brain from swallowing the whole workspace, including the
    /// user's own messages.
    private func pullSlack(account: String, userId: String, apiKey: String) async throws -> [ContextItem] {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let day = Self.dayFormatter.string(from: yesterday)
        var seen = Set<String>()
        var items: [ContextItem] = []

        for query in SlackHarvestFilter.searchQueries(after: day) {
            guard let json = try? await executeTool(
                "SLACK_SEARCH_MESSAGES",
                account: account,
                userId: userId,
                apiKey: apiKey,
                arguments: ["query": query, "count": 6, "sort": "timestamp", "sort_dir": "desc"]
            ) else { continue }
            let matches = ((json["messages"] as? [String: Any])?["matches"] as? [[String: Any]]) ?? []
            for match in matches {
                let text = (match["text"] as? String) ?? ""
                let channel = (match["channel"] as? [String: Any])?["name"] as? String ?? "channel"
                let user = (match["username"] as? String) ?? (match["user"] as? String) ?? "someone"
                let key = "\(channel)|\(user)|\(text.prefix(120))"
                guard !seen.contains(key), SlackHarvestFilter.shouldKeep(text: text, author: user) else { continue }
                seen.insert(key)
                items.append(ContextItem(title: "#\(channel) — \(user)", body: text, source: "slack", date: nil))
                if items.count >= 8 { return items }
            }
        }
        return items
    }

    // MARK: - Transport

    private func executeTool(_ slug: String, account: String, userId: String, apiKey: String,
                             arguments: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: base.appendingPathComponent("tools/execute/\(slug)"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = ["connected_account_id": account, "user_id": userId, "arguments": arguments]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await uploadBody(URLSession.shared, for: request, body: payload)
        try Self.checkOK(response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectorError.http(0, L("\(slug) 응답 형식이 올바르지 않아요.", "\(slug) returned a malformed response."))
        }
        if let successful = json["successful"] as? Bool, successful == false {
            let message = ((json["error"] as? [String: Any])?["message"] as? String)
                ?? (json["error"] as? String)
                ?? L("도구 오류", "tool error")
            throw ConnectorError.http(0, "\(slug): \(message)")
        }
        return (json["data"] as? [String: Any]) ?? [:]
    }

    private static func checkOK(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let message = String(data: data, encoding: .utf8) ?? ""
            throw ConnectorError.http(status, String(message.prefix(300)))
        }
    }
}

// MARK: - Wire models

private struct ConnectedAccountsResponse: Decodable {
    let items: [Item]

    struct Item: Decodable {
        let id: String
        let status: String
        let toolkit: Toolkit?

        struct Toolkit: Decodable {
            let slug: String
        }
    }
}

private struct AuthConfigsResponse: Decodable {
    let items: [Item]

    struct Item: Decodable {
        let id: String
    }
}

private struct LinkResponse: Decodable {
    let redirectUrl: String
    let connectedAccountId: String?
}
