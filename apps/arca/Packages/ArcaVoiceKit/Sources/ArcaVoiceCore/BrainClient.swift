import Foundation

/// One remembered sentence on its way to ARCA Brain (`/api/brain/remember`).
public struct BrainEntry: Codable, Sendable, Equatable {
    public var text: String
    public var kind: String
    public var source: String
    public var sourceRef: String?
    public var createdAt: Date

    public init(text: String, kind: String = "fact", source: String = "chat",
                sourceRef: String? = nil, createdAt: Date = .now) {
        self.text = text
        self.kind = kind
        self.source = source
        self.sourceRef = sourceRef
        self.createdAt = createdAt
    }
}

/// What `/api/brain/context` returns: the three always-injected views, the
/// not-yet-consolidated buffer, and the page index. Rendered into the chat
/// system prompt by `promptBlock()`.
public struct BrainContext: Codable, Sendable, Equatable {
    public struct Views: Codable, Sendable, Equatable {
        public var essentials: String
        public var threads: String
        public var recent: String
        public init(essentials: String = "", threads: String = "", recent: String = "") {
            self.essentials = essentials
            self.threads = threads
            self.recent = recent
        }
    }
    public struct BufferItem: Codable, Sendable, Equatable {
        public var text: String
        public var source: String
        public var createdAt: Date
        public init(text: String, source: String, createdAt: Date) {
            self.text = text
            self.source = source
            self.createdAt = createdAt
        }
    }
    public struct PageCard: Codable, Sendable, Equatable {
        public var slug: String
        public var title: String
        public var summary: String
        public init(slug: String, title: String, summary: String) {
            self.slug = slug
            self.title = title
            self.summary = summary
        }
    }

    public var views: Views
    public var buffer: [BufferItem]
    public var pages: [PageCard]
    public var updatedAt: Date?

    public init(views: Views = Views(), buffer: [BufferItem] = [], pages: [PageCard] = [], updatedAt: Date? = nil) {
        self.views = views
        self.buffer = buffer
        self.pages = pages
        self.updatedAt = updatedAt
    }

    public var isEmpty: Bool {
        views.essentials.isEmpty && views.threads.isEmpty && views.recent.isEmpty
            && buffer.isEmpty && pages.isEmpty
    }

    /// The system-prompt block. Sections with nothing in them are omitted so a
    /// fresh account doesn't get five empty headers. Sized for a prompt, not a
    /// dump: buffer and page index are capped, page bodies are never inlined —
    /// the model reads a page on demand through `search_memory`.
    public func promptBlock(maxBuffer: Int = 40, maxPages: Int = 60) -> String {
        guard !isEmpty else { return "" }
        var sections: [String] = []
        if !views.essentials.isEmpty { sections.append("## Essentials\n\(views.essentials)") }
        if !views.threads.isEmpty { sections.append("## Threads\n\(views.threads)") }
        if !views.recent.isEmpty { sections.append("## Recent\n\(views.recent)") }
        if !buffer.isEmpty {
            let lines = buffer.prefix(maxBuffer).map { "- [\(Self.stamp($0.createdAt)) · \($0.source)] \($0.text)" }
            sections.append("## 아직 정리 안 된 최근 기억\n" + lines.joined(separator: "\n"))
        }
        if !pages.isEmpty {
            let lines = pages.prefix(maxPages).map { "- \($0.slug) — \($0.summary)" }
            sections.append("## 기억 페이지 (필요하면 search_memory로 본문을 읽는다)\n" + lines.joined(separator: "\n"))
        }
        return """

        Long-term memory (ARCA Brain) — what you already know about the user. \
        Use it naturally; never recite it:
        \(sections.joined(separator: "\n\n"))
        """
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}

/// ARCA Brain: the memory that lives on the server so every device — and a
/// device that is switched off — shares one set of memories. The client is
/// thin on purpose: append sentences, fetch the rendered context, cache it.
/// Every failure degrades to "no brain context this turn"; nothing here may
/// block or break a chat.
public enum BrainClient {
    /// `…/api/arca/cloud` → `…/api/brain`.
    public static var baseURL: URL {
        ArcaCloud.baseURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("brain")
    }
    static let cacheKey = "brainContextCache"
    private static let timeout: TimeInterval = 20

    /// Either credential opens Brain: the invite code (the same grant the cloud
    /// proxies check, `lib/cloud.ts`) or this install's device token
    /// (`lib/arca/device.ts`). Neither one, no server memory — local facts
    /// still work.
    public static var isAvailable: Bool {
        ArcaCloud.inviteToken != nil || ArcaCloudAccount.storedToken != nil
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func request(_ path: String, method: String = "GET") -> URLRequest? {
        // Both when both exist: an invited tester on a device that has also
        // minted an identity is one user, and the server picks whichever
        // credential the route understands. `storedToken` deliberately reads
        // what is already in the Keychain — minting is a network round trip and
        // has no business on the path that writes a memory.
        let invite = ArcaCloud.inviteToken
        let device = ArcaCloudAccount.storedToken
        guard invite != nil || device != nil else { return nil }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        if let invite { request.setValue(invite, forHTTPHeaderField: "x-arca-token") }
        if let device { request.setValue(device, forHTTPHeaderField: "x-arca-device") }
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = timeout
        return request
    }

    /// Appends entries to the server buffer. Returns how many the server kept
    /// (nil when Brain is unavailable or the call failed).
    @discardableResult
    public static func remember(_ entries: [BrainEntry]) async -> Int? {
        let kept = entries.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !kept.isEmpty, var request = request("remember", method: "POST") else { return nil }
        struct Body: Encodable { let entries: [BrainEntry] }
        struct Reply: Decodable { let inserted: Int }
        guard let body = try? encoder.encode(Body(entries: Array(kept.prefix(50)))) else { return nil }
        request.httpBody = body
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let reply = try? decoder.decode(Reply.self, from: data) else { return nil }
        return reply.inserted
    }

    /// Fetches the current context and caches it for `cachedContext`.
    @discardableResult
    public static func refreshContext() async -> BrainContext? {
        guard let request = request("context") else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let context = try? decoder.decode(BrainContext.self, from: data) else { return nil }
        if let raw = try? encoder.encode(context), let text = String(data: raw, encoding: .utf8) {
            AccountDefaults.set(text, for: cacheKey)
        }
        return context
    }

    /// The last fetched context, or nil. Reading never touches the network.
    public static var cachedContext: BrainContext? {
        guard isAvailable, let text = AccountDefaults.string(cacheKey),
              let data = text.data(using: .utf8) else { return nil }
        return try? decoder.decode(BrainContext.self, from: data)
    }

    /// Asks the server to consolidate this owner's buffer now (settings "정리하기").
    public static func consolidateNow() async -> Bool {
        guard let request = request("consolidate", method: "POST") else { return false }
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: - Traction events (POST /api/brain/events)

    static let eventQueueKey = "brainEventQueue"

    struct EventBody: Encodable {
        struct E: Encodable { let kind: String }
        let events: [E]
    }

    /// Pure: the request body for a batch of event kinds (the server stamps `at`).
    static func eventsPayload(_ kinds: [String]) -> Data? {
        guard !kinds.isEmpty else { return nil }
        return try? encoder.encode(EventBody(events: kinds.map { .init(kind: $0) }))
    }

    static func pendingEventKinds() -> [String] {
        guard let text = AccountDefaults.string(eventQueueKey), let data = text.data(using: .utf8) else { return [] }
        return (try? decoder.decode([String].self, from: data)) ?? []
    }

    private static func saveQueue(_ kinds: [String]) {
        let capped = Array(kinds.suffix(500))
        if let data = try? encoder.encode(capped), let text = String(data: data, encoding: .utf8) {
            AccountDefaults.set(text, for: eventQueueKey)
        }
    }

    /// Records one traction event (`app_open`, `proposal_approved`, `loop_closed`, …).
    /// Never blocks and never throws: the kind is queued in AccountDefaults so an
    /// offline day still counts, and a flush is attempted in the background. No
    /// credential, no server memory, no event — same rule as `remember`.
    public static func track(_ kind: String) {
        guard isAvailable else { return }
        saveQueue(pendingEventKinds() + [kind])
        Task.detached(priority: .utility) { await flushEvents() }
    }

    /// Sends up to 100 queued events. Returns the server's accepted count, nil on
    /// failure — in which case the queue is kept for the next attempt.
    @discardableResult
    public static func flushEvents() async -> Int? {
        let queued = pendingEventKinds()
        guard !queued.isEmpty, var request = request("events", method: "POST") else { return nil }
        let batch = Array(queued.prefix(100))
        guard let body = eventsPayload(batch) else { return nil }
        request.httpBody = body
        struct Reply: Decodable { let accepted: Int }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let reply = try? decoder.decode(Reply.self, from: data) else { return nil }
        saveQueue(Array(queued.dropFirst(batch.count)))
        return reply.accepted
    }
}
