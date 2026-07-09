import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import ArcaVoiceKit

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// "Connectors" screen — lets the user connect Composio-backed sources,
/// export local memory to Obsidian, and import read-only memory from membase.
struct ConnectorsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var obsidianVaultPath = ""
    @State private var hub = ConnectorHub()
    @State private var isSyncing = false
    @State private var selectedSlugs: Set<String> = []
    @State private var pendingConnectionSlugs: Set<String> = []
    @State private var isBatchConnecting = false
    @State private var connectingSlug: String?
    @State private var pullingSlug: String?
    @State private var connectError: String?
    @State private var showingVaultPicker = false
    @State private var obsidianExportResult: String?
    @State private var isExportingObsidian = false
    #if os(macOS)
    @State private var isImportingMembase = false
    @State private var membaseResult: String?
    #endif

    private var disconnectedConnectors: [ConnectorInfo] {
        ConnectorHub.catalog.filter { hub.accounts[$0.slug] == nil }
    }

    private var selectedDisconnectedSlugs: [String] {
        disconnectedConnectors.map(\.slug).filter { selectedSlugs.contains($0) }
    }

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
                    batchConnectHeader
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 4, trailing: 16))

                    ForEach(ConnectorHub.catalog) { connector in
                        ConnectorRow(
                            connector: connector,
                            accountId: hub.accounts[connector.slug],
                            isSelected: selectedSlugs.contains(connector.slug),
                            isPending: pendingConnectionSlugs.contains(connector.slug) && hub.accounts[connector.slug] == nil,
                            isConnecting: connectingSlug == connector.slug,
                            isPulling: pullingSlug == connector.slug,
                            onSelect: { toggleSelection(connector) },
                            onConnect: { connect(connector) },
                            onPull: { pullOne(connector) }
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .swipeActions(edge: .trailing) {
                            if hub.accounts[connector.slug] != nil {
                                Button(action: { pullOne(connector) }) {
                                    Label(connector.slug == "SLACK" ? "Slack 대화 가져오기" : "가져오기",
                                          systemImage: "arrow.down.circle")
                                }
                                .tint(ConnectorPalette.ember)
                            }
                        }
                    }
                } header: {
                    Text("Composio 커넥터")
                }

                Section {
                    ObsidianConnectorRow(
                        vaultPath: obsidianVaultPath,
                        isExporting: isExportingObsidian,
                        resultText: obsidianExportResult,
                        onChooseFolder: { showingVaultPicker = true },
                        onExport: exportToObsidian
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))

                    #if os(macOS)
                    MembaseConnectorRow(
                        isImporting: isImportingMembase,
                        resultText: membaseResult,
                        onImport: importFromMembase
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    #endif
                } header: {
                    Text("기타 커넥터")
                }

                Section {
                    Text("Composio 계정으로 OAuth 커넥터를 관리합니다. 연결된 항목은 ARCA 메모리로 컨텍스트를 가져올 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.03, green: 0.05, blue: 0.09).ignoresSafeArea())
            .navigationTitle("커넥터")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .refreshable { await refreshAndPrune() }
            .task {
                loadScopedSettings()
                setDefaultObsidianVaultIfNeeded()
                await refreshAndPrune()
            }
            .fileImporter(isPresented: $showingVaultPicker, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    obsidianVaultPath = url.path
                    AccountDefaults.set(url.path, for: "obsidianVaultPath")
                    obsidianExportResult = nil
                case .failure(let error):
                    obsidianExportResult = error.localizedDescription
                }
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ARCA가 이미 알고 있어야 할 컨텍스트를 연결합니다.")
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
                    Text(isSyncing ? "동기화 중…" : "컨텍스트 동기화")
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
            Text("\(hub.accounts.count)개 연결됨 · 가져온 항목은 메모리 사실로 저장됩니다")
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

    private var batchConnectHeader: some View {
        HStack(spacing: 12) {
            Button(action: toggleAllDisconnected) {
                HStack(spacing: 8) {
                    Image(systemName: allDisconnectedSelected ? "checkmark.square.fill" : "square")
                        .foregroundStyle(allDisconnectedSelected ? ConnectorPalette.green : .secondary)
                    Text("모두 선택")
                        .foregroundStyle(.white)
                }
                .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .disabled(disconnectedConnectors.isEmpty)

            Spacer()

            Button(action: connectSelected) {
                HStack(spacing: 8) {
                    if isBatchConnecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "link.badge.plus")
                    }
                    Text("선택 항목 연결 (\(selectedDisconnectedSlugs.count))")
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(ConnectorPalette.ember, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(selectedDisconnectedSlugs.isEmpty || isBatchConnecting)
        }
        .padding(.horizontal, 2)
    }

    private var allDisconnectedSelected: Bool {
        let slugs = Set(disconnectedConnectors.map(\.slug))
        return !slugs.isEmpty && slugs.isSubset(of: selectedSlugs)
    }

    private func toggleAllDisconnected() {
        let slugs = Set(disconnectedConnectors.map(\.slug))
        if allDisconnectedSelected {
            selectedSlugs.subtract(slugs)
        } else {
            selectedSlugs.formUnion(slugs)
        }
    }

    private func toggleSelection(_ connector: ConnectorInfo) {
        guard hub.accounts[connector.slug] == nil else { return }
        if selectedSlugs.contains(connector.slug) {
            selectedSlugs.remove(connector.slug)
        } else {
            selectedSlugs.insert(connector.slug)
        }
    }

    private func syncAll() {
        guard !isSyncing else { return }
        isSyncing = true
        Task {
            await hub.pullAllIntoMemory(context: modelContext)
            isSyncing = false
        }
    }

    private func connectSelected() {
        let slugs = selectedDisconnectedSlugs
        guard !slugs.isEmpty, !isBatchConnecting else { return }
        isBatchConnecting = true
        connectError = nil
        pendingConnectionSlugs.formUnion(slugs)

        Task {
            for (index, slug) in slugs.enumerated() {
                guard hub.accounts[slug] == nil else { continue }
                do {
                    let url = try await hub.connectURL(for: slug)
                    openExternal(url)
                    if index < slugs.count - 1 {
                        try? await Task.sleep(for: .seconds(1))
                    }
                } catch {
                    connectError = "\(displayName(for: slug)): \(error.localizedDescription)"
                    pendingConnectionSlugs.remove(slug)
                }
            }
            isBatchConnecting = false
            await pollConnections(for: slugs)
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
                pendingConnectionSlugs.insert(connector.slug)
                openExternal(url)
                await pollConnections(for: [connector.slug])
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

    private func pollConnections(for slugs: [String]) async {
        let targets = Set(slugs)
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            await hub.refresh()
            selectedSlugs.subtract(Set(hub.accounts.keys))
            pendingConnectionSlugs.subtract(Set(hub.accounts.keys))
            if targets.allSatisfy({ hub.accounts[$0] != nil }) { return }
            try? await Task.sleep(for: .seconds(3))
        }
        let remaining = targets.filter { hub.accounts[$0] == nil }
        pendingConnectionSlugs.subtract(remaining)
        if !remaining.isEmpty {
            connectError = "연결 대기 시간이 초과되었습니다: \(remaining.map(displayName(for:)).joined(separator: ", "))"
        }
    }

    private func refreshAndPrune() async {
        await hub.refresh()
        let connected = Set(hub.accounts.keys)
        selectedSlugs.subtract(connected)
        pendingConnectionSlugs.subtract(connected)
    }

    private func exportToObsidian() {
        guard !isExportingObsidian else { return }
        isExportingObsidian = true
        obsidianExportResult = nil
        Task {
            defer { isExportingObsidian = false }
            do {
                let count = try ObsidianExporter.exportAll(
                    to: URL(fileURLWithPath: obsidianVaultPath, isDirectory: true),
                    context: modelContext
                )
                obsidianExportResult = "\(count)개 파일 내보냄"
            } catch {
                obsidianExportResult = error.localizedDescription
            }
        }
    }

    #if os(macOS)
    private func importFromMembase() {
        guard !isImportingMembase else { return }
        isImportingMembase = true
        membaseResult = nil
        Task {
            defer { isImportingMembase = false }
            do {
                let existingFacts = (try? modelContext.fetch(FetchDescriptor<MemoryFact>())) ?? []
                let imported = try await MembaseBridge().importRecentMemories(limit: 50)
                let dedupe = MembaseBridge.deduplicate(
                    incoming: imported,
                    existing: Set(existingFacts.map(\.text))
                )
                for text in dedupe.newTexts {
                    modelContext.insert(MemoryFact(text: text, kind: "fact", source: "membase"))
                }
                try? modelContext.save()
                membaseResult = "\(dedupe.newTexts.count)개 가져옴 (중복 \(dedupe.skippedCount)개 건너뜀)"
            } catch {
                membaseResult = error.localizedDescription
            }
        }
    }
    #endif

    private func setDefaultObsidianVaultIfNeeded() {
        guard AccountStore.isDefault(AccountStore.currentAccountId()),
              obsidianVaultPath.isEmpty else { return }
        let defaultURL = URL(fileURLWithPath: "/Users/minsungpark/MY ZONE/ME", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: defaultURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            obsidianVaultPath = defaultURL.path
            AccountDefaults.set(defaultURL.path, for: "obsidianVaultPath")
        }
    }

    private func loadScopedSettings() {
        obsidianVaultPath = AccountDefaults.string("obsidianVaultPath") ?? ""
    }

    private func displayName(for slug: String) -> String {
        ConnectorHub.catalog.first(where: { $0.slug == slug })?.displayName ?? slug
    }

    private func openExternal(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #elseif os(iOS)
        UIApplication.shared.open(url)
        #else
        _ = url
        #endif
    }
}

enum ConnectorPalette {
    static let ember = Color(red: 1.0, green: 0.478, blue: 0.102)
    static let green = Color(red: 0.32, green: 0.86, blue: 0.45)
}

private struct ConnectorRow: View {
    let connector: ConnectorInfo
    let accountId: String?
    let isSelected: Bool
    let isPending: Bool
    let isConnecting: Bool
    let isPulling: Bool
    let onSelect: () -> Void
    let onConnect: () -> Void
    let onPull: () -> Void
    private var isConnected: Bool { accountId != nil }

    var body: some View {
        HStack(spacing: 12) {
            if isConnected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(ConnectorPalette.green)
                    .frame(width: 24)
            } else {
                Button(action: onSelect) {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 18))
                        .foregroundStyle(isSelected ? ConnectorPalette.green : .secondary)
                        .frame(width: 24)
                }
                .buttonStyle(.plain)
                .disabled(isPending)
            }

            Image(systemName: connector.symbol)
                .font(.system(size: 17))
                .foregroundStyle(isConnected ? ConnectorPalette.green : .secondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(connector.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(isConnected ? ConnectorPalette.green : .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isConnected {
                Button(action: onPull) {
                    HStack(spacing: 6) {
                        if isPulling {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.down.circle")
                        }
                        Text(connector.slug == "SLACK" ? "Slack 대화 가져오기" : "가져오기")
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isPulling)

                pill(text: "연결됨", filled: true)
            } else if isPending {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(action: onConnect) {
                    if isConnecting {
                        ProgressView().controlSize(.mini)
                            .padding(.horizontal, 12)
                    } else {
                        pill(text: "연결", filled: false)
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
                    Capsule().fill(ConnectorPalette.green)
                } else {
                    Capsule().strokeBorder(ConnectorPalette.ember, lineWidth: 1.5)
                }
            }
    }

    private var statusText: String {
        if isConnected {
            if let accountId {
                return "연결됨 ✓ · \(String(accountId.suffix(8)))"
            }
            return "연결됨 ✓"
        }
        if isPending { return "연결 대기 중…" }
        return "미연결"
    }
}

private struct ObsidianConnectorRow: View {
    let vaultPath: String
    let isExporting: Bool
    let resultText: String?
    let onChooseFolder: () -> Void
    let onExport: () -> Void

    private var isConnected: Bool {
        guard !vaultPath.isEmpty else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: vaultPath, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    var body: some View {
        LocalConnectorCard(
            symbol: "shippingbox.fill",
            title: "Obsidian",
            status: isConnected ? "연결됨" : "미연결",
            statusColor: isConnected ? ConnectorPalette.green : .secondary,
            resultText: resultText
        ) {
            VStack(alignment: .trailing, spacing: 8) {
                Button(action: onChooseFolder) {
                    Label(isConnected ? "볼트 변경" : "볼트 선택", systemImage: "folder")
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.bold))
                .foregroundStyle(ConnectorPalette.ember)

                Button(action: onExport) {
                    HStack(spacing: 6) {
                        if isExporting {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                        Text("메모리 내보내기")
                    }
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .opacity(isConnected ? 1 : 0.5)
                .disabled(!isConnected || isExporting)
            }
        } detail: {
            if isConnected {
                Text(vaultPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

#if os(macOS)
private struct MembaseConnectorRow: View {
    let isImporting: Bool
    let resultText: String?
    let onImport: () -> Void

    var body: some View {
        LocalConnectorCard(
            symbol: "brain.head.profile",
            title: "membase",
            status: "읽기 전용",
            statusColor: .secondary,
            resultText: resultText
        ) {
            Button(action: onImport) {
                HStack(spacing: 6) {
                    if isImporting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.down.doc")
                    }
                    Text("메모리 가져오기")
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(isImporting)
        } detail: {
            EmptyView()
        }
    }
}
#endif

private struct LocalConnectorCard<Actions: View, Detail: View>: View {
    let symbol: String
    let title: String
    let status: String
    let statusColor: Color
    let resultText: String?
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(statusColor)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
                detail()
                if let resultText {
                    Text(resultText)
                        .font(.caption2)
                        .foregroundStyle(resultText.contains("필요") || resultText.contains("실패") ? .orange : .secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)
            actions()
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

#Preview {
    ConnectorsView()
        .modelContainer(for: [
            MemoryFact.self,
            RecordingSession.self,
            AudioAsset.self,
            StoredSegment.self,
            SessionNote.self,
            SpeakerRecord.self,
        ], inMemory: true)
}
