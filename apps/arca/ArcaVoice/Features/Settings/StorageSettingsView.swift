import SwiftUI
import SwiftData
import ArcaVoiceKit

/// Settings › Storage: what takes space, the audio retention rule, and a
/// button to apply it now.
struct StorageSettingsView: View {
    @Environment(\.modelContext) private var context
    @State private var janitor = StorageJanitor.shared
    @State private var retention = StorageJanitor.shared.retentionDays
    @State private var trimmedNotice: String?

    var body: some View {
        Form {
            Section {
                row(L("녹음 오디오", "Recording audio"), StorageJanitor.format(janitor.report.audioBytes),
                    detail: L("\(janitor.report.audioSessions)개 회의", "\(janitor.report.audioSessions) meetings"))
                row(L("하루 기록 스냅샷", "Day log snapshots"), StorageJanitor.format(janitor.report.dayLogBytes), detail: L("14일 보관", "kept 14 days"))
                row(L("로그", "Logs"), StorageJanitor.format(janitor.report.logBytes), detail: L("1MB 넘으면 자동 정리", "trimmed past 1 MB"))
            } header: {
                Text(L("사용 중", "In use"))
            }

            Section {
                Picker(L("녹음 오디오 보관", "Keep recording audio"), selection: $retention) {
                    ForEach(StorageJanitor.retentionChoices, id: \.self) { days in
                        Text(days == 0 ? L("계속 보관", "Forever") : L("\(days)일", "\(days) days")).tag(days)
                    }
                }
                .onChange(of: retention) { _, value in
                    janitor.retentionDays = value
                    janitor.measure(context: context)
                }
                if janitor.report.purgeableSessions > 0 {
                    HStack {
                        Text(L("지금 정리하면 \(janitor.report.purgeableSessions)개 회의의 오디오 \(StorageJanitor.format(janitor.report.purgeableBytes))가 비워져요.",
                               "Cleaning now frees \(StorageJanitor.format(janitor.report.purgeableBytes)) of audio across \(janitor.report.purgeableSessions) meetings."))
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("지금 정리", "Clean now")) {
                            let n = janitor.purge(context: context)
                            trimmedNotice = L("\(n)개 회의의 오디오를 정리했어요.", "Cleared audio for \(n) meetings.")
                        }
                        .disabled(janitor.isWorking)
                    }
                }
                if let trimmedNotice {
                    Text(trimmedNotice).font(.caption).foregroundStyle(.green)
                }
            } header: {
                Text(L("보관 규칙", "Retention"))
            } footer: {
                Text(L("보관 기간이 지나면 오디오 파일만 지워지고, 전사·요약·결정·액션 아이템은 그대로 남아요. 새 녹음은 음성용 40kbps로 저장돼 예전의 절반 이하 크기예요.",
                       "After the retention period only the audio file is removed; transcript, summary, decisions and action items stay. New recordings use speech-grade 40 kbps, under half the old size."))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("저장 공간", "Storage"))
        .task { janitor.measure(context: context) }
    }

    private func row(_ title: String, _ value: String, detail: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
