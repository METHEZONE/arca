import SwiftUI
import SwiftData
import ArcaVoiceKit

/// "Connectors" screen — lets the user see which Composio-backed sources
/// (Gmail, Calendar, Drive, Slack, …) are connected, connect new ones, and
/// pull recent context from them into ARCA's on-device memory.
struct ConnectorsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @State private var hub = ConnectorHub()
    @State private var isSyncing = false
    @State private var connectingSlug: String?
    @State private var pullingSlug: String?
    @State private var connectError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    headerCard
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }

                Section {
                    ForEach(ConnectorHub.catalog) { connector in
                        ConnectorRow(
                            connector: connector,
                            accountId: hub.accounts[connector.slug],
                            isConnecting: connectingSlug == connector.slug,
                            isPulling: pullingSlug == connector.slug,
                            onConnect: { connect(connector) },
                            onPull: { pullOne(connector) }
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .swipeActions(edge: .trailing) {
                            if hub.accounts[connector.slug] != nil {
                                Button(action: { pullOne(connector) }) {
                                    Label("Pull", systemImage: "arrow.down.circle")
                                }
                                .tint(ConnectorPalette.ember)
                            }
                        }
                    }
                } header: {
                    Text("Sources")
                }

                Section {
                    Text("Powered by your Composio account. Manage auth configs at app.composio.dev.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.03, green: 0.05, blue: 0.09).ignoresSafeArea())
            .navigationTitle("Connectors")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .refreshable { await hub.refresh() }
            .task { await hub.refresh() }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect your world — ARCA pulls context so it already knows.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: syncAll) {
                HStack(spacing: 8) {
                    if isSyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(isSyncing ? "Syncing…" : "Sync context")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(ConnectorPalette.ember, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isSyncing)

            if !hub.lastPullSummary.isEmpty {
                Text(hub.lastPullSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\(hub.accounts.count) connected · pulled items become Memory Brain facts")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let error = connectError ?? hub.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func syncAll() {
        guard !isSyncing else { return }
        isSyncing = true
        Task {
            await hub.pullAllIntoMemory(context: modelContext)
            isSyncing = false
        }
    }

    private func connect(_ connector: ConnectorInfo) {
        guard connectingSlug == nil else { return }
        connectingSlug = connector.slug
        connectError = nil
        Task {
            defer { connectingSlug = nil }
            do {
                let url = try await hub.connectURL(for: connector.slug)
                openURL(url)
            } catch {
                connectError = error.localizedDescription
            }
        }
    }

    private func pullOne(_ connector: ConnectorInfo) {
        guard pullingSlug == nil else { return }
        pullingSlug = connector.slug
        Task {
            defer { pullingSlug = nil }
            await hub.pullOneIntoMemory(toolkit: connector.slug, context: modelContext)
        }
    }
}

enum ConnectorPalette {
    static let ember = Color(red: 1.0, green: 0.478, blue: 0.102)
}

private struct ConnectorRow: View {
    let connector: ConnectorInfo
    let accountId: String?
    let isConnecting: Bool
    let isPulling: Bool
    let onConnect: () -> Void
    let onPull: () -> Void
    private var isConnected: Bool { accountId != nil }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: connector.symbol)
                .font(.system(size: 17))
                .foregroundStyle(isConnected ? ConnectorPalette.ember : .secondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(connector.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isConnected {
                Button(action: onPull) {
                    if isPulling {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isPulling)

                pill(text: "Connected", filled: true)
            } else {
                Button(action: onConnect) {
                    if isConnecting {
                        ProgressView().controlSize(.mini)
                            .padding(.horizontal, 12)
                    } else {
                        pill(text: "Connect", filled: false)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isConnecting)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func pill(text: String, filled: Bool) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(filled ? Color.black : ConnectorPalette.ember)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                if filled {
                    Capsule().fill(ConnectorPalette.ember)
                } else {
                    Capsule().strokeBorder(ConnectorPalette.ember, lineWidth: 1.5)
                }
            }
    }

    private var statusText: String {
        guard let accountId else { return "Not connected" }
        return "Ready · \(String(accountId.suffix(8)))"
    }
}

#Preview {
    ConnectorsView()
        .modelContainer(for: MemoryFact.self, inMemory: true)
}
