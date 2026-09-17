import Foundation
import SwiftUI
import WatchKit

/// The iPhone's ARCA to-dos, mirrored to the wrist. The phone pushes the open
/// list as application context ("latest wins"); completing one here goes back
/// as a queued message so it lands even if the phone is out of range right now.
@MainActor
@Observable
final class WatchTodoStore {
    static let shared = WatchTodoStore()

    struct Item: Codable, Identifiable, Sendable {
        var id: String
        var title: String
        var due: Date?
        var done = false
    }

    private(set) var items: [Item] = []
    private static let key = "watchTodos"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        }
    }

    var open: [Item] { items.filter { !$0.done } }

    func receive(_ incoming: [Item]) {
        items = incoming
        persist()
    }

    func complete(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].done = true
        persist()
        WatchSync.shared.send(todoDone: id)
        WKInterfaceDevice.current().play(.success)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

/// The page below the companion: what needs doing, straight from the phone.
struct TodoListView: View {
    @State private var store = WatchTodoStore.shared

    var body: some View {
        Group {
            if store.open.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.title3)
                        .foregroundStyle(.green)
                    Text(L("할 일이 없어요", "Nothing to do"))
                        .font(.footnote.weight(.semibold))
                    Text(L("아이폰 ARCA의 할 일이 여기에 보여요.", "To-dos from ARCA on your iPhone show up here."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                List {
                    Text(L("할 일", "To-do"))
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .listRowBackground(Color.clear)
                    ForEach(store.open) { item in
                        Button {
                            withAnimation(.snappy) { store.complete(item.id) }
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "circle")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.orange)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.system(.footnote, design: .rounded, weight: .medium))
                                        .lineLimit(3)
                                    if let due = item.due {
                                        Text(due, style: .relative)
                                            .font(.caption2)
                                            .foregroundStyle(due < .now ? .orange : .secondary)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        // No navigation title on a paged screen: watchOS puts it top-right,
        // straight over the page dots.
        .onAppear { WatchSync.shared.requestTodos() }
    }
}
