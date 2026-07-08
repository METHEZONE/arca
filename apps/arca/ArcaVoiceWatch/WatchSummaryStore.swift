import Foundation
import WatchKit

/// Summaries that came back from the iPhone after a Watch recording finished
/// processing. UserDefaults-backed — a handful of recent items is all the
/// wrist needs; the phone/Mac library is the real archive.
@MainActor
@Observable
final class WatchSummaryStore {
    static let shared = WatchSummaryStore()

    struct Item: Codable, Identifiable, Sendable {
        var id: String            // session uid
        var title: String
        var summary: String
        var actions: [String]
        var receivedAt: Date
    }

    private(set) var items: [Item] = []
    /// Set when a new summary lands while the app is open — drives the badge.
    private(set) var hasUnread = false

    private static let key = "watchSummaries"
    private static let maxItems = 5

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        }
    }

    func receive(uid: String, title: String, summary: String, actions: [String], at: Date) {
        items.removeAll { $0.id == uid }
        items.insert(Item(id: uid, title: title, summary: summary, actions: actions, receivedAt: at),
                     at: 0)
        if items.count > Self.maxItems { items = Array(items.prefix(Self.maxItems)) }
        hasUnread = true
        persist()
        WKInterfaceDevice.current().play(.success)
    }

    func markRead() {
        hasUnread = false
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
