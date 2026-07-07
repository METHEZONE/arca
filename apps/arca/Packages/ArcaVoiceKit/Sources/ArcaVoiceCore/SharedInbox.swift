import Foundation

/// Cross-process handoff between the share extension and the app, via the
/// shared App Group container. The extension drops items here; the app drains
/// them on foreground and offers to act on them ("이거 만들어드릴까요?").
public enum SharedInbox {
    public static let appGroupID = "group.com.thezone.arca.voice"

    public struct Item: Codable, Sendable, Identifiable {
        public enum Kind: String, Codable, Sendable { case image, text, url }
        public var id: UUID
        public var kind: Kind
        /// Relative filename within the inbox dir for image items; nil otherwise.
        public var fileName: String?
        public var text: String?
        public var createdAt: Date

        public init(id: UUID = UUID(), kind: Kind, fileName: String? = nil,
                    text: String? = nil, createdAt: Date) {
            self.id = id
            self.kind = kind
            self.fileName = fileName
            self.text = text
            self.createdAt = createdAt
        }
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static var inboxDir: URL? {
        guard let base = containerURL else { return nil }
        let dir = base.appendingPathComponent("inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Called by the share extension. Persists item bytes + a manifest entry.
    public static func enqueue(kind: Item.Kind, imageData: Data? = nil, text: String? = nil,
                               createdAt: Date) {
        guard let dir = inboxDir else { return }
        var fileName: String?
        if let imageData {
            let name = "\(UUID().uuidString).jpg"
            try? imageData.write(to: dir.appendingPathComponent(name))
            fileName = name
        }
        let item = Item(kind: kind, fileName: fileName, text: text, createdAt: createdAt)
        let manifest = dir.appendingPathComponent("\(item.id.uuidString).json")
        if let data = try? JSONEncoder().encode(item) {
            try? data.write(to: manifest)
        }
    }

    /// Called by the app. Returns pending items (newest first).
    public static func pending() -> [Item] {
        guard let dir = inboxDir,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Item.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public static func imageURL(for item: Item) -> URL? {
        guard let fileName = item.fileName, let dir = inboxDir else { return nil }
        return dir.appendingPathComponent(fileName)
    }

    public static func remove(_ item: Item) {
        guard let dir = inboxDir else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(item.id.uuidString).json"))
        if let fileName = item.fileName {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(fileName))
        }
    }
}
