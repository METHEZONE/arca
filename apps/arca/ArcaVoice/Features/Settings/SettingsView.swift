import SwiftUI
import ArcaVoiceKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ownerName") private var ownerName = "Me"
    @AppStorage("transcribeLocale") private var localeID = "auto"
    @AppStorage("autoEmailSummary") private var autoEmailSummary = true
    @AppStorage("summaryEmailRecipient") private var emailRecipient = "me@thezonebio.com"
    @AppStorage("chatHotkey") private var chatHotkey = "rightCommand"
    @AppStorage("chatModel") private var chatModel = "claude-sonnet-5"
    @AppStorage("autonomyLevel") private var autonomyRaw = AutonomyLevel.readOnly.rawValue
    @AppStorage("notchStyle") private var notchStyle = "cozy"
    @AppStorage("ambientHarvest") private var ambientHarvest = true
    @AppStorage("slackMentionHandles") private var slackMentionHandles = ""
    @AppStorage("slackSelfNames") private var slackSelfNames = ""
    @State private var openAIKey = ""
    @State private var anthropicKey = ""
    @State private var saved = false

    var body: some View {
        Form {
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
            } header: {
                Text("Summary Email")
            } footer: {
                Text("Sent via the ARCA Gmail connection (Composio) in ~/.arca. Includes the summary, decisions, and action plan.")
            }
            #endif
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(minWidth: 440, minHeight: 400)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear {
            openAIKey = KeychainStore.get(.openAI) ?? ""
            anthropicKey = KeychainStore.get(.anthropic) ?? ""
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
}
