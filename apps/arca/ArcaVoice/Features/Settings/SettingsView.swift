import SwiftUI
import ArcaVoiceKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var language = ArcaLanguage.shared
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
    @AppStorage("vitalsEnabled") private var vitalsEnabled = true
    @AppStorage("vitalsPollMinutes") private var vitalsPollMinutes = 10
    @AppStorage("vitalsWriteToHealth") private var vitalsWriteToHealth = true
    @AppStorage("vitalsShareToRelay") private var vitalsShareToRelay = true
    @AppStorage(MorningNotifier.enabledKey) private var morningBriefEnabled = false
    @AppStorage(MorningNotifier.hourKey) private var morningBriefHour = 8
    @AppStorage("nightlyObsidianDigest") private var nightlyDigest = true
    @AppStorage("nightlyDigestHour") private var nightlyDigestHour = 21
    @State private var connectorHub = ConnectorHub()
    #if os(macOS)
    @State private var permissionCoach = MacPermissionCoach.shared
    #endif
    @State private var connectingSlug: String?
    @State private var composioKey = ""
    @State private var composioUserId = ""
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
    @State private var transcriptionEngine = EngineFactory.transcriptionEngine
    @State private var saved = false

    var body: some View {
        Form {
            accountSection

            Section {
                NavigationLink {
                    ConnectorsView()
                } label: {
                    Label(L("커넥터", "Connectors"), systemImage: "app.connected.to.app.below.fill")
                }
                NavigationLink {
                    SkinsView()
                } label: {
                    Label(L("스킨", "Skins"), systemImage: "paintpalette.fill")
                }
                NavigationLink {
                    BrainView()
                } label: {
                    Label(L("메모리 브레인", "Memory Brain"), systemImage: "brain.head.profile")
                }
            } footer: {
                Text(L("Gmail, 캘린더, 드라이브, Slack까지 — ARCA가 컨텍스트를 먼저 가져와서 이미 알고 있어요.",
                       "Gmail, Calendar, Drive, Slack and more — ARCA pulls context so it already knows."))
            }

            Section {
                Picker(L("언어", "Language"), selection: Binding(
                    get: { language.choice },
                    set: { language.set($0) }
                )) {
                    ForEach(ArcaLanguage.Choice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
            } header: {
                Text(L("언어", "Language"))
            } footer: {
                Text(L("맥과 아이폰이 같은 언어로 보이도록 두 앱이 같은 설정을 씁니다. 기기 설정을 따라가면 아이폰과 맥의 시스템 언어를 각각 따릅니다.",
                       "Both apps share this setting so the Mac and the iPhone read the same way. Following the device setting means each one follows its own system language."))
            }

            Section(L("내 정보", "My Info")) {
                TextField(L("이름 (전사에서 내 발화에 붙는 이름)",
                            "Your name (label for your speech in transcripts)"),
                          text: $ownerName)
                Picker(L("전사 언어", "Transcription language"), selection: $localeID) {
                    Text(L("한국어/영어 섞어서 (자동)", "Korean/English mixed (auto)")).tag("auto")
                    Text(L("한국어", "Korean")).tag("ko-KR")
                    Text(L("영어", "English")).tag("en-US")
                }
            }

            Section {
                SecureField(L("OpenAI API 키 (sk-…)", "OpenAI API Key (sk-…)"), text: $openAIKey)
                SecureField(L("Anthropic API 키 (sk-ant-…)", "Anthropic API Key (sk-ant-…)"), text: $anthropicKey)
                Button(saved ? L("저장됐어요 ✓", "Saved ✓") : L("키 저장", "Save keys")) {
                    #if os(iOS)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    #endif
                    saveKeys()
                }
            } header: {
                Text(L("API 키 (BYOK)", "API Keys (BYOK)"))
            } footer: {
                Text(L("키는 이 기기의 키체인에만 저장됩니다. 맥에서는 ~/.arca/voice-keys.json에 있는 키를 첫 실행 때 자동으로 불러옵니다. OpenAI 키 = 고품질 전사와 화자 분리, Anthropic 키 = 회의 요약과 노트 완성.",
                       "Keys are stored only in this device's Keychain. On Mac, keys in ~/.arca/voice-keys.json are loaded automatically on first launch. OpenAI key = high-quality transcription & speaker separation, Anthropic key = meeting summaries & note completion."))
            }

            transcriptionEngineSection

            #if os(macOS)
            permissionsSection
            #endif

            connectorsSection

            #if os(macOS)
            nightlyDigestSection
            #endif

            vitalsSection

            Section {
                Toggle(L("앰비언트 운영 — 받은 메일을 할 일과 답장 초안으로",
                         "Ambient ops — inbox to tasks & reply drafts"),
                       isOn: $ambientHarvest)
                TextField(L("나를 부르는 Slack 핸들", "Slack handles that ping me"),
                          text: $slackMentionHandles)
                TextField(L("무시할 내 Slack 이름", "My Slack names to ignore"),
                          text: $slackSelfNames)
            } footer: {
                Text(L("Slack 핸들과 이름을 쉼표로 구분해 적어주세요. ARCA는 나를 부르는 말이나 실제로 처리할 일만 찾고, 여기 적힌 내 이름에서 온 메시지는 무시하며, 답장은 당신이 확인한 뒤에만 나갑니다.",
                       "Comma-separated Slack handles/names. ARCA searches only likely pings or actionable asks, ignores messages from these self names, and drafts replies you approve before anything is sent."))
            }

            #if os(macOS)
            Section {
                Picker(L("노치 존재감", "Notch presence"), selection: $notchStyle) {
                    Text(L("코지 — 눈이 살짝 보여요", "Cozy — eyes peek out")).tag("cozy")
                    Text(L("클린 — 노치만", "Clean — just the notch")).tag("clean")
                }
            } footer: {
                Text(L("코지는 ARCA의 눈을 노치 바로 아래에 두고 커서를 느긋하게 따라가게 합니다. 클린은 무슨 일이 생길 때까지 ARCA를 숨기고요 — 마우스를 올리면 대시보드는 그대로 열립니다.",
                       "Cozy keeps ARCA's eyes just under the notch, lazily following your cursor. Clean hides ARCA until something happens — hover still opens the dashboard."))
            }

            Section {
                Picker(L("자율성 단계", "Autonomy level"), selection: $autonomyRaw) {
                    ForEach(AutonomyLevel.allCases, id: \.rawValue) { level in
                        Text(level.label).tag(level.rawValue)
                    }
                }
                Text((AutonomyLevel(rawValue: autonomyRaw) ?? .readOnly).detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(L("ARCA 자율성", "ARCA Autonomy"))
            } footer: {
                Text(L("ZONE 중에 들어온 할 일과 항목을 ARCA가 어디까지 혼자 처리할지 정합니다. 이 단계로 부족한 일은 Toss 버튼 없이 당신이 직접 처리하도록 남겨둡니다.",
                       "Sets how far ARCA can act on its own for tasks and items that come in during ZONE. Anything that needs more than this level stays for you to handle directly, without a Toss button."))
            }

            Section {
                Picker(L("화면 캡처 핫키", "Screen capture hotkey"), selection: $chatHotkey) {
                    ForEach(ChatHotkey.allCases) { key in
                        Text(key.label).tag(key.rawValue)
                    }
                }
                Picker(L("ARCA 챗 모델", "ARCA chat model"), selection: $chatModel) {
                    Text("Claude Sonnet 5").tag("claude-sonnet-5")
                    Text("Claude Opus 4.8").tag("claude-opus-4-8")
                    Text("Claude Fable 5").tag("claude-fable-5")
                }
            } header: {
                Text(L("ARCA 라이브 챗", "ARCA Live Chat"))
            } footer: {
                Text(L("핫키를 두 번 누르면 전체 화면을 캡처하고 바로 대화가 시작됩니다. 스크린샷을 노치로 끌어다 놓아도 돼요. 브라우저 조작이 필요하면 ARCA가 Codex로 실행할지 물어봅니다. (전역 핫키에는 손쉬운 사용 권한이 필요합니다.)",
                       "Double-tap the hotkey to capture the full screen and start chatting right away. You can also drag a screenshot onto the notch. If browser control is needed, ARCA will offer to run it via Codex. (Global hotkeys require Accessibility permission.)"))
            }

            Section {
                Toggle(L("회의가 끝나면 요약을 자동으로 메일로 보내기",
                         "Automatically email a summary when a meeting ends"),
                       isOn: $autoEmailSummary)
                TextField(L("받는 사람 이메일", "Recipient email"), text: $emailRecipient)
                    .disabled(!autoEmailSummary)
                    .onChange(of: emailRecipient) { _, value in
                        AccountDefaults.set(value, for: "summaryEmailRecipient")
                    }
                Toggle(L("회의록 Obsidian 자동 저장", "Save meeting notes to Obsidian automatically"),
                       isOn: $autoObsidianExport)
                #if os(macOS)
                Toggle(L("회의 참가자 자동 인식 — 통화 화면에서 이름을 읽어 전사에 반영",
                         "Recognize meeting attendees — reads names off the call window into the transcript"),
                       isOn: $autoRosterCapture)
                #endif
            } header: {
                Text(L("요약 메일", "Summary Email"))
            } footer: {
                Text(summaryFooterText)
            }

            Section {
                Toggle(L("데이 트래커 켜기", "Turn on the Day Tracker"), isOn: $dayTrackerEnabled)
                Toggle(L("스냅샷 포함", "Include snapshots"), isOn: $dayTrackerSnapshots)
                    .disabled(!dayTrackerEnabled)
                Picker(L("간격", "Interval"), selection: $dayTrackerIntervalMin) {
                    Text(L("3분", "3 min")).tag(3)
                    Text(L("5분", "5 min")).tag(5)
                    Text(L("10분", "10 min")).tag(10)
                }
                .disabled(!dayTrackerEnabled || !dayTrackerSnapshots)
                Picker(L("자동 정리 시각", "Digest time"), selection: $dayTrackerDigestHour) {
                    ForEach(18...23, id: \.self) { hour in
                        Text(L("\(hour)시", "\(hour):00")).tag(hour)
                    }
                }
                .disabled(!dayTrackerEnabled)
            } header: {
                Text(L("데이 트래커", "Day Tracker"))
            } footer: {
                Text(L("모든 기록은 이 Mac에만 저장됩니다. 정리 생성 시에만 샘플 스냅샷이 AI로 전송됩니다.",
                       "Everything stays on this Mac. Sample snapshots go to the AI only when you generate a digest."))
            }
            .onChange(of: dayTrackerEnabled) { _, _ in AppServices.shared.dayLog.applySettings() }
            .onChange(of: dayTrackerSnapshots) { _, _ in AppServices.shared.dayLog.applySettings() }
            .onChange(of: dayTrackerIntervalMin) { _, _ in AppServices.shared.dayLog.applySettings() }
            .onChange(of: dayTrackerDigestHour) { _, _ in AppServices.shared.dayLog.applySettings() }
            #endif
        }
        .formStyle(.grouped)
        .navigationTitle(L("설정", "Settings"))
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 400)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L("완료", "Done")) { dismiss() }
            }
        }
        .onAppear {
            reloadAccounts()
            loadScopedSettings()
            openAIKey = KeychainStore.get(.openAI) ?? ""
            anthropicKey = KeychainStore.get(.anthropic) ?? ""
        }
        .alert(L("계정 추가", "Add account"), isPresented: $showingAddAccount) {
            TextField(L("이름", "Name"), text: $newAccountName)
            TextField(L("이메일(선택)", "Email (optional)"), text: $newAccountEmail)
            Button(L("추가", "Add")) { addAccount() }
            Button(L("취소", "Cancel"), role: .cancel) { }
        } message: {
            Text(L("새 계정은 기존 데이터와 키를 건드리지 않고 별도 위치를 사용합니다.",
                   "A new account gets its own space and leaves your existing data and keys untouched."))
        }
    }

    #if os(macOS)
    private var permissionsSection: some View {
        Section {
            ForEach(MacPermission.allCases) { permission in
                let granted = permission.isGranted
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(granted ? ConnectorPalette.green : .orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(permission.title)
                            Text(granted ? L("허용됨", "Allowed") : L("허용 안 됨", "Not allowed"))
                                .font(.caption2)
                                .foregroundStyle(granted ? ConnectorPalette.green : .orange)
                        }
                        Spacer()
                        if !granted {
                            Button(permission.acceptsAppDrop
                                   ? L("끌어다 놓기로 허용", "Allow by drag")
                                   : L("설정 열기", "Open Settings")) {
                                permissionCoach.begin(permission)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    Text(permission.why)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if permissionCoach.grantedJustNow == permission,
                       permission.needsRelaunchAfterGrant {
                        HStack(spacing: 8) {
                            Text(L("허용됐어요. 이 권한은 다시 시작해야 완전히 적용돼요.",
                                   "Allowed. This one only fully takes effect after a restart."))
                                .font(.caption)
                                .foregroundStyle(ConnectorPalette.green)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(L("다시 시작", "Restart")) { permissionCoach.relaunch() }
                                .controlSize(.small)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text(L("권한", "Permissions"))
        } footer: {
            Text(L("ARCA가 해당 설정 창을 열고, 그 위에 아이콘을 띄워줘요 — 목록으로 끌어다 놓으면 끝입니다. 목록의 + 를 눌러 앱을 찾아야 하는 단계를 건너뜁니다.",
                   "ARCA opens the right Settings pane and floats its icon over it — drop it in the list and you're done. It skips the part where you have to hunt for the app behind the + button."))
        }
    }
    #endif
    /// macOS permissions, with a way to actually grant them.
    ///
    /// The failure this fixes: the Screen Recording and Accessibility panes make
    /// you click `+`, then find the app in a file picker that opens somewhere
    /// unhelpful. Everyone gets stuck there. So ARCA opens the exact pane and
    /// floats its own icon over it to drag straight into the list.
    /// Which engine finishes a recording — the single biggest lever on cost.
    ///
    /// Transcription dwarfs everything else on the bill: summaries run to a few
    /// cents a meeting, while an hour of two-channel audio is two billable hours
    /// every single time. The device can do that part for nothing, so the free
    /// engine is the default and paying is a deliberate choice for diarization.
    private var transcriptionEngineSection: some View {
        Section {
            Picker(L("전사 엔진", "Transcription engine"), selection: $transcriptionEngine) {
                ForEach(TranscriptionEngine.allCases) { engine in
                    Text(engine.title).tag(engine)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .onChange(of: transcriptionEngine) { _, engine in
                EngineFactory.transcriptionEngine = engine
            }

            Text(transcriptionEngine.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if transcriptionEngine == .cloudDiarized, !EngineFactory.hasFinalPassKey {
                Label(L("OpenAI 키가 없어서 이 엔진은 아직 못 써요.",
                        "No OpenAI key yet, so this engine can't run."),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text(L("전사", "Transcription"))
        } footer: {
            Text(L("녹음 중에는 언제나 기기에서 무료로 전사해요 — 와이파이가 없어도 글자는 남습니다. 여기서 고르는 건 녹음이 끝난 뒤의 마무리 패스예요.",
                   "While recording, ARCA always transcribes on-device for free — the words survive even with no network. This setting picks what runs after the recording ends."))
        }
    }


    /// Connectors, inline.
    ///
    /// They used to live only behind a `NavigationLink` push, and the pushed
    /// screen has a history of collapsing to zero height on macOS — so the honest
    /// answer to "did I connect anything?" was invisible from the one screen where
    /// people look for it. Now the state and the connect buttons are right here,
    /// and the full screen stays available for bulk actions.
    private var connectorsSection: some View {
        Section {
            if !connectorHub.isConfigured {
                VStack(alignment: .leading, spacing: 8) {
                    Label(L("Composio 키가 없어 커넥터를 연결할 수 없어요",
                            "No Composio key, so connectors can't be linked"),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(L("아래에 키와 사용자 ID를 넣으면 바로 연결할 수 있어요. 맥에서는 ~/.arca/connections.json 에 있으면 자동으로 읽어옵니다.",
                           "Paste a key and user id below to link them. On the Mac, ARCA also reads them from ~/.arca/connections.json automatically."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SecureField(L("Composio API 키", "Composio API key"), text: $composioKey)
                TextField(L("Composio 사용자 ID", "Composio user id"), text: $composioUserId)
                Button(L("키 저장하고 새로고침", "Save and refresh")) {
                    saveComposioCredentials()
                }
                .disabled(composioKey.trimmingCharacters(in: .whitespaces).isEmpty
                          || composioUserId.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            ForEach(ConnectorHub.catalog) { connector in
                HStack(spacing: 10) {
                    Image(systemName: connector.symbol)
                        .frame(width: 20)
                        .foregroundStyle(connectorHub.accounts[connector.slug] != nil
                                         ? ConnectorPalette.green : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(connector.displayName)
                        Text(connectorHub.accounts[connector.slug] != nil
                             ? L("연결됨", "Connected")
                             : L("미연결", "Not connected"))
                            .font(.caption2)
                            .foregroundStyle(connectorHub.accounts[connector.slug] != nil
                                             ? ConnectorPalette.green : .secondary)
                    }
                    Spacer()
                    if connectorHub.accounts[connector.slug] == nil {
                        Button(L("연결", "Connect")) {
                            connectFromSettings(connector)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!connectorHub.isConfigured || connectingSlug == connector.slug)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(ConnectorPalette.green)
                    }
                }
            }

            NavigationLink {
                ConnectorsView()
            } label: {
                Label(L("커넥터 전체 화면 (가져오기·Obsidian·membase)",
                        "All connectors (import, Obsidian, membase)"),
                      systemImage: "app.connected.to.app.below.fill")
            }
        } header: {
            Text(L("커넥터", "Connectors"))
        } footer: {
            Text(connectorFooter)
        }
        .task { await connectorHub.refresh() }
    }

    private var connectorFooter: String {
        if let error = connectorHub.lastError {
            return error
        }
        let count = connectorHub.accounts.count
        return L("\(count)개 연결됨 · 연결하면 Gmail·캘린더·Slack 등의 맥락을 ARCA가 미리 알고 있습니다. 애플 건강과 Obsidian은 전체 화면에서 연결해요.",
                 "\(count) connected · linking these lets ARCA already know your mail, calendar and Slack context. Apple Health and Obsidian are on the full screen.")
    }

    private func saveComposioCredentials() {
        let key = composioKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let userId = composioUserId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !userId.isEmpty else { return }
        try? KeychainStore.set(key, for: .composio)
        AccountDefaults.set(userId, for: "composioUserId")
        composioKey = ""
        Task { await connectorHub.refresh() }
    }

    private func connectFromSettings(_ connector: ConnectorInfo) {
        guard connectingSlug == nil else { return }
        connectingSlug = connector.slug
        Task {
            defer { connectingSlug = nil }
            do {
                let url = try await connectorHub.connectURL(for: connector.slug)
                #if os(macOS)
                NSWorkspace.shared.open(url)
                #else
                await UIApplication.shared.open(url)
                #endif
                // OAuth completes in a browser, so poll until the account appears.
                for _ in 0..<40 {
                    try? await Task.sleep(for: .seconds(3))
                    await connectorHub.refresh()
                    if connectorHub.accounts[connector.slug] != nil { return }
                }
            } catch {
                // `lastError` on the hub already carries it into the footer.
            }
        }
    }

    #if os(macOS)
    /// The evening pass. On by default — the whole point is that context keeps
    /// accumulating without the user remembering to ask for it.
    private var nightlyDigestSection: some View {
        Section {
            Toggle(L("매일 저녁 옵시디언에 하루 정리", "Nightly Obsidian digest"),
                   isOn: $nightlyDigest)
            Picker(L("정리 시각", "Digest time"), selection: $nightlyDigestHour) {
                ForEach(18...23, id: \.self) { hour in
                    Text(L("\(hour)시", "\(hour):00")).tag(hour)
                }
            }
            .disabled(!nightlyDigest)
            Button(L("지금 정리하기", "Run it now")) {
                guard let context = AppServices.shared.container?.mainContext else { return }
                Task { await NightlyDigest.shared.runNow(context: context) }
            }
            .disabled(NightlyDigest.shared.isRunning)
            if let result = NightlyDigest.shared.lastResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(L("하루 정리", "Daily digest"))
        } footer: {
            Text(L("워치·아이폰·맥에서 녹음된 모든 회의록을 옵시디언에 모으고, 하루가 끝나면 회의들을 가로지르는 인사이트를 함께 정리합니다. 개별 회의록은 녹음이 끝나는 대로 바로 나갑니다.",
                   "Gathers every note recorded on your watch, iPhone or Mac into Obsidian, and at the end of the day adds the insights that cut across them. Individual notes go out as soon as a recording finishes."))
        }
        .onChange(of: nightlyDigest) { _, value in NightlyDigest.shared.setEnabled(value) }
        .onChange(of: nightlyDigestHour) { _, _ in NightlyDigest.shared.refreshSettings() }
    }
    #endif

    /// Body + focus tracking. The footer states plainly where the data goes,
    /// because "health app that quietly uploads your heart data" is the thing a
    /// user is right to be suspicious of.
    private var vitalsSection: some View {
        Section {
            Toggle(L("바이탈 추적 — 몰입 준비도·수면·스트레스",
                     "Vitals tracking — Readiness · Sleep · Stress"),
                   isOn: $vitalsEnabled)
            Picker(L("측정 간격", "Reading interval"), selection: $vitalsPollMinutes) {
                Text(L("5분", "5 min")).tag(5)
                Text(L("10분", "10 min")).tag(10)
                Text(L("30분", "30 min")).tag(30)
            }
            .disabled(!vitalsEnabled)
            #if os(iOS)
            Toggle(L("말로 기록한 식사를 애플 건강에 쓰기", "Write meals I log by voice to Apple Health"),
                   isOn: $vitalsWriteToHealth)
                .disabled(!vitalsEnabled)
            Button(L("건강 권한 다시 요청", "Ask for Health access again")) {
                Task { await VitalsEngine.shared.requestPermission() }
            }
            .disabled(!vitalsEnabled)
            #endif
            Toggle(L("내 기기끼리 공유 (맥에서도 보기)", "Share across my devices"),
                   isOn: $vitalsShareToRelay)
                .disabled(!vitalsEnabled)
            Toggle(L("아침 브리핑 알림", "Morning brief notification"), isOn: $morningBriefEnabled)
            Picker(L("알림 시각", "Brief time"), selection: $morningBriefHour) {
                ForEach(5...11, id: \.self) { hour in
                    Text(L("\(hour)시", "\(hour):00")).tag(hour)
                }
            }
            .disabled(!morningBriefEnabled)
        } header: {
            Text(L("바이탈", "Vitals"))
        } footer: {
            Text(vitalsFooterText)
        }
        .onChange(of: vitalsEnabled) { _, value in VitalsEngine.shared.setEnabled(value) }
        .onChange(of: vitalsPollMinutes) { _, _ in VitalsEngine.shared.applySettings() }
        .onChange(of: vitalsWriteToHealth) { _, _ in VitalsEngine.shared.applySettings() }
        .onChange(of: vitalsShareToRelay) { _, _ in VitalsEngine.shared.applySettings() }
        .onChange(of: morningBriefEnabled) { _, _ in Task { await MorningNotifier.reschedule() } }
        .onChange(of: morningBriefHour) { _, _ in Task { await MorningNotifier.reschedule() } }
    }

    private var vitalsFooterText: String {
        #if os(macOS)
        return L("""
        맥에는 애플 건강이 없습니다. 여기 보이는 수치는 아이폰이 측정해서 개인 릴레이 저장소(arca-brain)로 \
        보내준 것이고, 회의 전사가 이미 오가는 그 경로와 같습니다. '기기끼리 공유'를 끄면 맥은 바이탈을 \
        받지 않습니다. 몰입 시간대 프로필은 이 맥의 앱 전환 기록과 ZONE 세션으로 여기서 직접 만듭니다.
        """, """
        macOS has no Apple Health. What you see here was measured by your iPhone and sent through your own \
        relay store (arca-brain) — the same path your meeting transcripts already travel. Turn off \
        'Share across my devices' and the Mac stops receiving vitals. Your focus-window profile is built \
        right here, from this Mac's app-switch history and your ZONE sessions.
        """)
        #else
        return L("""
        애플워치가 이미 기록해 둔 값을 읽기만 합니다 — ARCA가 센서를 켜지 않으니 배터리를 먹지 않아요. \
        실시간 측정은 워치에서 직접 누를 때만 그 몇 분간 돌아갑니다. 데이터는 이 기기에 남고, \
        '기기끼리 공유'를 켜면 내 개인 릴레이 저장소를 거쳐 맥에서도 보입니다. \
        ARCA는 의료 기기가 아니며 진단하지 않습니다.
        """, """
        ARCA only reads what your Apple Watch already recorded — it never turns on a sensor, so it costs \
        you no battery. A live reading runs for those few minutes only when you start it on the Watch \
        yourself. The data stays on this device, and with 'Share across my devices' on it reaches your Mac \
        through your own relay store. ARCA is not a medical device and does not diagnose.
        """)
        #endif
    }

    private var accountSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(currentAccount.displayName)
                        .font(.headline)
                    if AccountStore.isDefault(currentAccount.id) {
                        Text(L("기본 계정", "Default account"))
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
                    Label(L("계정 추가…", "Add account…"), systemImage: "plus")
                }
            } label: {
                Label(L("계정 선택", "Switch account"), systemImage: "person.crop.circle")
            }
        } header: {
            Text(L("계정", "Account"))
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
        // Recordings that were saved with only an on-device transcript because
        // there was no key can be finished now. Doing it here rather than on the
        // next launch is the difference between a key that visibly worked and a
        // key that seems to have done nothing.
        PassRetryScheduler.shared.keysChanged()
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            saved = false
        }
    }

    private var summaryFooterText: String {
        let vault = obsidianVaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let vaultText = vault.isEmpty
            ? L("커넥터에서 볼트를 연결하세요", "Connect a vault in Connectors")
            : vault
        return L("~/.arca에 있는 ARCA의 Gmail 연결(Composio)로 보냅니다. 요약과 결정, 액션 플랜이 함께 담깁니다.\nObsidian: \(vaultText)",
                 "Sent via the ARCA Gmail connection (Composio) in ~/.arca. Includes the summary, decisions, and action plan.\nObsidian: \(vaultText)")
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
        accountNotice = L("계정 전환은 ARCA를 다시 시작한 후 적용됩니다.",
                          "Switching accounts takes effect after you restart ARCA.")
    }

    private func addAccount() {
        let account = AccountStore.add(displayName: newAccountName, email: newAccountEmail)
        AccountStore.switchTo(id: account.id)
        reloadAccounts()
        loadScopedSettings()
        openAIKey = KeychainStore.get(.openAI) ?? ""
        anthropicKey = KeychainStore.get(.anthropic) ?? ""
        accountNotice = L("계정 전환은 ARCA를 다시 시작한 후 적용됩니다.",
                          "Switching accounts takes effect after you restart ARCA.")
    }

    private func loadScopedSettings() {
        emailRecipient = AccountDefaults.string("summaryEmailRecipient") ?? "me@thezonebio.com"
        obsidianVaultPath = AccountDefaults.string("obsidianVaultPath") ?? ""
    }
}
