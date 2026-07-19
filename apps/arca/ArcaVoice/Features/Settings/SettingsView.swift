import SwiftUI
import ArcaVoiceKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ownerName") private var ownerName = "Me"
    @AppStorage("transcribeLocale") private var localeID = "auto"
    @AppStorage("autoEmailSummary") private var autoEmailSummary = true
    @AppStorage("autoObsidianExport") private var autoObsidianExport = true
    @AppStorage("chatHotkey") private var chatHotkey = "rightCommand"
    @AppStorage("chatModel") private var chatModel = "claude-sonnet-5"
    @AppStorage("autonomyLevel") private var autonomyRaw = AutonomyLevel.readOnly.rawValue
    @AppStorage("notchStyle") private var notchStyle = "cozy"
    @AppStorage("ambientHarvest") private var ambientHarvest = true
    @AppStorage("slackMentionHandles") private var slackMentionHandles = ""
    @AppStorage("slackSelfNames") private var slackSelfNames = ""
    @AppStorage("dayTrackerEnabled") private var dayTrackerEnabled = false
    @AppStorage("dayTrackerSnapshots") private var dayTrackerSnapshots = true
    @AppStorage("dayTrackerIntervalMin") private var dayTrackerIntervalMin = 5
    @AppStorage("dayTrackerDigestHour") private var dayTrackerDigestHour = 21
    @State private var emailRecipient = "me@thezonebio.com"
    @State private var obsidianVaultPath = ""
    @State private var accounts: [ArcaAccount] = []
    @State private var currentAccount = AccountStore.current()
    @State private var showingAddAccount = false
    @State private var newAccountName = ""
    @State private var newAccountEmail = ""
    @State private var accountNotice: String?
    @State private var openAIKey = ""
    @State private var anthropicKey = ""
    @State private var saved = false

    var body: some View {
        Form {
            accountSection

            Section {
                NavigationLink {
                    ConnectorsView()
                } label: {
                    Label("Connectors", systemImage: "app.connected.to.app.below.fill")
                }
                NavigationLink {
                    SkinsView()
                } label: {
                    Label("Skins", systemImage: "paintpalette.fill")
                }
                NavigationLink {
                    BrainView()
                } label: {
                    Label("Memory Brain", systemImage: "brain.head.profile")
                }
            } footer: {
                Text("Gmail, Calendar, Drive, Slack and more — ARCA pulls context so it already knows.")
            }

            Section("My Info") {
                TextField("Your name (label for your speech in transcripts)", text: $ownerName)
                Picker("Transcription language", selection: $localeID) {
                    Text("Korean/English mixed (auto)").tag("auto")
                    Text("Korean").tag("ko-KR")
                    Text("English").tag("en-US")
                }
            }

            Section {
                SecureField("OpenAI API Key (sk-…)", text: $openAIKey)
                SecureField("Anthropic API Key (sk-ant-…)", text: $anthropicKey)
                Button(saved ? "Saved ✓" : "Save keys") {
                    #if os(iOS)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    #endif
                    saveKeys()
                }
            } header: {
                Text("API Keys (BYOK)")
            } footer: {
                Text("Keys are stored only in this device's Keychain. On Mac, keys in ~/.arca/voice-keys.json are loaded automatically on first launch. OpenAI key = high-quality transcription & speaker separation, Anthropic key = meeting summaries & note completion.")
            }

            Section {
                Toggle("Ambient ops — inbox to tasks & reply drafts", isOn: $ambientHarvest)
                TextField("Slack handles that ping me", text: $slackMentionHandles)
                TextField("My Slack names to ignore", text: $slackSelfNames)
            } footer: {
                Text("Comma-separated Slack handles/names. ARCA searches only likely pings or actionable asks, ignores messages from these self names, and drafts replies you approve before anything is sent.")
            }

            #if os(macOS)
            Section {
                Picker("Notch presence", selection: $notchStyle) {
                    Text("Cozy — eyes peek out").tag("cozy")
                    Text("Clean — just the notch").tag("clean")
                }
            } footer: {
                Text("Cozy keeps ARCA's eyes just under the notch, lazily following your cursor. Clean hides ARCA until something happens — hover still opens the dashboard.")
            }

            Section {
                Picker("Autonomy level", selection: $autonomyRaw) {
                    ForEach(AutonomyLevel.allCases, id: \.rawValue) { level in
                        Text(level.label).tag(level.rawValue)
                    }
                }
                Text((AutonomyLevel(rawValue: autonomyRaw) ?? .readOnly).detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("ARCA Autonomy")
            } footer: {
                Text("Sets how far ARCA can act on its own for tasks and items that come in during ZONE. Anything that needs more than this level stays for you to handle directly, without a Toss button.")
            }

            Section {
                Picker("Screen capture hotkey", selection: $chatHotkey) {
                    ForEach(ChatHotkey.allCases) { key in
                        Text(key.label).tag(key.rawValue)
                    }
                }
                Picker("ARCA chat model", selection: $chatModel) {
                    Text("Claude Sonnet 5").tag("claude-sonnet-5")
                    Text("Claude Opus 4.8").tag("claude-opus-4-8")
                    Text("Claude Fable 5").tag("claude-fable-5")
                }
            } header: {
                Text("ARCA Live Chat")
            } footer: {
                Text("Double-tap the hotkey to capture the full screen and start chatting right away. You can also drag a screenshot onto the notch. If browser control is needed, ARCA will offer to run it via Codex. (Global hotkeys require Accessibility permission.)")
            }

            Section {
                Toggle("Automatically email a summary when a meeting ends", isOn: $autoEmailSummary)
                TextField("Recipient email", text: $emailRecipient)
                    .disabled(!autoEmailSummary)
                    .onChange(of: emailRecipient) { _, value in
                        AccountDefaults.set(value, for: "summaryEmailRecipient")
                    }
                Toggle("회의록 Obsidian 자동 저장", isOn: $autoObsidianExport)
            } header: {
                Text("Summary Email")
            } footer: {
                Text(summaryFooterText)
            }

            Section {
                Toggle("데이 트래커 켜기", isOn: $dayTrackerEnabled)
                Toggle("스냅샷 포함", isOn: $dayTrackerSnapshots)
                    .disabled(!dayTrackerEnabled)
                Picker("간격", selection: $dayTrackerIntervalMin) {
                    Text("3분").tag(3)
                    Text("5분").tag(5)
                    Text("10분").tag(10)
                }
                .disabled(!dayTrackerEnabled || !dayTrackerSnapshots)
                Picker("자동 정리 시각", selection: $dayTrackerDigestHour) {
                    ForEach(18...23, id: \.self) { hour in
                        Text("\(hour)시").tag(hour)
                    }
                }
                .disabled(!dayTrackerEnabled)
            } header: {
                Text("데이 트래커")
            } footer: {
                Text("모든 기록은 이 Mac에만 저장됩니다. 정리 생성 시에만 샘플 스냅샷이 AI로 전송됩니다.")
            }
            .onChange(of: dayTrackerEnabled) { _, _ in AppServices.shared.dayLog.applySettings() }
            .onChange(of: dayTrackerSnapshots) { _, _ in AppServices.shared.dayLog.applySettings() }
            .onChange(of: dayTrackerIntervalMin) { _, _ in AppServices.shared.dayLog.applySettings() }
            .onChange(of: dayTrackerDigestHour) { _, _ in AppServices.shared.dayLog.applySettings() }
            #endif
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 400)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear {
            reloadAccounts()
            loadScopedSettings()
            openAIKey = KeychainStore.get(.openAI) ?? ""
            anthropicKey = KeychainStore.get(.anthropic) ?? ""
        }
        .alert("계정 추가", isPresented: $showingAddAccount) {
            TextField("이름", text: $newAccountName)
            TextField("이메일(선택)", text: $newAccountEmail)
            Button("추가") { addAccount() }
            Button("취소", role: .cancel) { }
        } message: {
            Text("새 계정은 기존 데이터와 키를 건드리지 않고 별도 위치를 사용합니다.")
        }
    }

    private var accountSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(currentAccount.displayName)
                        .font(.headline)
                    if AccountStore.isDefault(currentAccount.id) {
                        Text("기본 계정")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.secondary.opacity(0.14), in: Capsule())
                    }
                }
                if let email = currentAccount.email, !email.isEmpty {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let accountNotice {
                    Text(accountNotice)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Menu {
                ForEach(accounts) { account in
                    Button {
                        switchAccount(account)
                    } label: {
                        Label(account.displayName, systemImage: account.id == currentAccount.id ? "checkmark" : "person")
                    }
                }
                Divider()
                Button {
                    newAccountName = ""
                    newAccountEmail = ""
                    showingAddAccount = true
                } label: {
                    Label("계정 추가…", systemImage: "plus")
                }
            } label: {
                Label("계정 선택", systemImage: "person.crop.circle")
            }
        } header: {
            Text("계정")
        }
    }

    private func saveKeys() {
        if openAIKey.isEmpty {
            KeychainStore.delete(.openAI)
        } else {
            try? KeychainStore.set(openAIKey, for: .openAI)
        }
        if anthropicKey.isEmpty {
            KeychainStore.delete(.anthropic)
        } else {
            try? KeychainStore.set(anthropicKey, for: .anthropic)
        }
        saved = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            saved = false
        }
    }

    private var summaryFooterText: String {
        let vault = obsidianVaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let vaultText = vault.isEmpty ? "Connectors에서 볼트를 연결하세요" : vault
        return "Sent via the ARCA Gmail connection (Composio) in ~/.arca. Includes the summary, decisions, and action plan.\nObsidian: \(vaultText)"
    }

    private func reloadAccounts() {
        accounts = AccountStore.all()
        currentAccount = AccountStore.current()
    }

    private func switchAccount(_ account: ArcaAccount) {
        AccountStore.switchTo(id: account.id)
        reloadAccounts()
        loadScopedSettings()
        openAIKey = KeychainStore.get(.openAI) ?? ""
        anthropicKey = KeychainStore.get(.anthropic) ?? ""
        accountNotice = "계정 전환은 ARCA를 다시 시작한 후 적용됩니다."
    }

    private func addAccount() {
        let account = AccountStore.add(displayName: newAccountName, email: newAccountEmail)
        AccountStore.switchTo(id: account.id)
        reloadAccounts()
        loadScopedSettings()
        openAIKey = KeychainStore.get(.openAI) ?? ""
        anthropicKey = KeychainStore.get(.anthropic) ?? ""
        accountNotice = "계정 전환은 ARCA를 다시 시작한 후 적용됩니다."
    }

    private func loadScopedSettings() {
        emailRecipient = AccountDefaults.string("summaryEmailRecipient") ?? "me@thezonebio.com"
        obsidianVaultPath = AccountDefaults.string("obsidianVaultPath") ?? ""
    }
}
