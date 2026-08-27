import SwiftUI
import ArcaVoiceKit
#if os(macOS)
import AppKit
#endif

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ownerName") private var ownerName = "Me"
    @AppStorage("transcribeLocale") private var localeID = "auto"
    @AppStorage("autoEmailSummary") private var autoEmailSummary = true
    @AppStorage("autoObsidianExport") private var autoObsidianExport = true
    @AppStorage("autoRosterCapture") private var autoRosterCapture = true
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
    @AppStorage(ArcaLang.defaultsKey) private var appLanguage = "system"
    @AppStorage(DocumentVault.defaultsKey) private var documentVaultPath = ""
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

            ArcaCloudSection()

            Section(L("My Info", ko: "내 정보")) {
                TextField(L("Your name (label for your speech in transcripts)",
                            ko: "이름 (전사에서 내 발언 라벨)"), text: $ownerName)
                Picker(L("Language", ko: "언어"), selection: $appLanguage) {
                    Text(L("Match system", ko: "시스템 언어 따라가기")).tag("system")
                    Text("한국어").tag("ko")
                    Text("English").tag("en")
                }
                Picker(L("Transcription language", ko: "전사 언어"), selection: $localeID) {
                    Text(L("Korean/English mixed (auto)", ko: "한/영 혼합 (자동)")).tag("auto")
                    Text(L("Korean", ko: "한국어")).tag("ko-KR")
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
                Toggle(L("Ambient ops — inbox to tasks & reply drafts",
                         ko: "앰비언트 옵스 — 받은편지함을 할 일과 답장 초안으로"),
                       isOn: $ambientHarvest)
                TextField(L("Slack handles that ping me", ko: "나를 부르는 Slack 핸들"),
                          text: $slackMentionHandles)
                TextField(L("My Slack names to ignore", ko: "무시할 내 Slack 이름"),
                          text: $slackSelfNames)
            } footer: {
                Text(L("Comma-separated Slack handles/names. ARCA searches only likely pings or actionable asks, ignores messages from these self names, and drafts replies you approve before anything is sent.",
                       ko: "쉼표로 구분한 Slack 핸들/이름. ARCA는 나를 부르는 메시지와 실제 요청만 골라내고, 보내기 전에 항상 승인을 받아요."))
            }

            #if os(macOS)
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Document vault", ko: "문서함"))
                        Text(documentVaultDisplayPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button(L("Choose…", ko: "폴더 선택…")) { pickDocumentVault() }
                }
            } footer: {
                Text(L("A folder of official documents (business registration cert, bank copy, …). When an email asks for one, ARCA proposes a reply with the file attached — you approve before it sends.",
                       ko: "사업자등록증, 통장사본 같은 공식 서류 폴더예요. 이메일로 서류를 요청받으면 ARCA가 파일을 첨부한 회신을 제안하고, 승인해야 발송돼요."))
            }
            #endif

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
                Picker(L("Autonomy level", ko: "자율성 레벨"), selection: $autonomyRaw) {
                    ForEach(AutonomyLevel.allCases, id: \.rawValue) { level in
                        Text(level.label).tag(level.rawValue)
                    }
                }
                Text((AutonomyLevel(rawValue: autonomyRaw) ?? .readOnly).detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(L("ARCA Autonomy", ko: "ARCA 자율성"))
            } footer: {
                Text(L("Sets how far ARCA can act on its own for tasks and items that come in during ZONE. Anything that needs more than this level stays for you to handle directly, without a Toss button.",
                       ko: "ARCA가 어디까지 스스로 움직일지 정해요. 이 레벨을 넘는 일은 Toss 버튼 없이 직접 처리하도록 남겨둬요."))
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
                #if os(macOS)
                Toggle("회의 참가자 자동 인식 — 통화 화면에서 이름을 읽어 전사에 반영", isOn: $autoRosterCapture)
                #endif
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

    #if os(macOS)
    private var documentVaultDisplayPath: String {
        if let folder = DocumentVault.folderURL {
            return folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
        return L("Not set — pick a folder", ko: "미설정 — 폴더를 선택하세요")
    }

    private func pickDocumentVault() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("Use this folder", ko: "이 폴더 사용")
        if panel.runModal() == .OK, let url = panel.url {
            documentVaultPath = url.path
        }
    }
    #endif

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
