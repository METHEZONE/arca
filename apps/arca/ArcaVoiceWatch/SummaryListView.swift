import SwiftUI

/// The page under the face: summaries that came back from the iPhone.
struct SummaryListView: View {
    @State private var store = WatchSummaryStore.shared
    @State private var transfers = WatchTransferStatus.shared

    private var inFlight: Bool { transfers.sending > 0 || transfers.awaitingSummary }

    var body: some View {
        Group {
            if store.items.isEmpty && !inFlight {
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Summaries land here after ARCA finishes on your iPhone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                List {
                    if inFlight {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(transfers.sending > 0
                                 ? "Sending to iPhone…"
                                 : "Processing on your iPhone…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(store.items) { item in
                        NavigationLink(value: item.id) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                                    .lineLimit(2)
                                Text(item.receivedAt, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .navigationDestination(for: String.self) { id in
                    if let item = store.items.first(where: { $0.id == id }) {
                        SummaryDetailView(item: item)
                    }
                }
            }
        }
        .navigationTitle("Summaries")
        .onAppear { store.markRead() }
    }
}

struct SummaryDetailView: View {
    let item: WatchSummaryStore.Item

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(item.title)
                    .font(.system(.footnote, design: .rounded, weight: .bold))

                Text(item.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if !item.actions.isEmpty {
                    Divider()
                    Text("ACTIONS")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    ForEach(Array(item.actions.enumerated()), id: \.offset) { _, action in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "circle")
                                .font(.system(size: 8))
                                .padding(.top, 4)
                                .foregroundStyle(.green)
                            Text(action)
                                .font(.footnote)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
    }
}
