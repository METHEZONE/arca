import SwiftUI

/// Behind the gear on the main screen. Small on purpose — the wrist is not
/// where settings live; these are the three the watch itself needs.
struct WatchSettingsView: View {
    @AppStorage("appLanguage") private var language = "korean"
    @AppStorage("liveVoiceReplies") private var voiceReplies = true
    @AppStorage("watchHaptics") private var haptics = true

    var body: some View {
        Form {
            Section(L("언어", "Language")) {
                Picker(L("워치 언어", "Watch language"), selection: $language) {
                    Text("한국어").tag("korean")
                    Text("English").tag("english")
                    Text(L("시스템 따라가기", "Follow system")).tag("system")
                }
            }
            Section(L("대화", "Talk")) {
                Toggle(L("ARCA 음성으로 답하기", "ARCA answers out loud"), isOn: $voiceReplies)
                Toggle(L("진동 피드백", "Haptics"), isOn: $haptics)
            }
            Section {
                Text(L("탭 — 대화 · 두 번 탭 — 녹음 · 꾹 — 빠른 메모",
                       "Tap — talk · double tap — record · hold — quick memo"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("ARCA \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .navigationTitle(L("설정", "Settings"))
    }
}
