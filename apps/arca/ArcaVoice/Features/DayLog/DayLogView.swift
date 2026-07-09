#if os(macOS)
import SwiftUI
import SwiftData
import ArcaVoiceKit

struct DayLogView: View {
    @State private var services = AppServices.shared
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<RecordingSession> { $0.sourceRaw == "dayLog" },
           sort: \RecordingSession.createdAt,
           order: .reverse)
    private var digests: [RecordingSession]

    let onOpenSession: (RecordingSession) -> Void

    private var engine: DayLogEngine { services.dayLog }
    private var topSummaries: [DayLogAppSummary] { Array(engine.todaySummaries.prefix(8)) }
    private var palette: [Color] { ArcaTheme.speakerColors }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                timelineSection
                snapshotsSection
                pastDigestsSection
            }
            .padding(28)
        }
        .background(Color(red: 0.03, green: 0.05, blue: 0.09))
        .onAppear {
            engine.applySettings()
            engine.reloadToday()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Date.now, format: .dateTime.year().month().day().weekday())
                    .font(.system(.title2, design: .rounded, weight: .bold))
                HStack(spacing: 8) {
                    statusPill
                    if !engine.isEnabled {
                        Button("켜기") { engine.setEnabled(true) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
            }
            Spacer()
            Button {
                Task {
                    if let session = await engine.generateTodayDigest(context: modelContext) {
                        onOpenSession(session)
                    }
                }
            } label: {
                Label(engine.isGenerating ? "정리 중" : "오늘 정리하기",
                      systemImage: engine.isGenerating ? "hourglass" : "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .tint(ArcaTheme.pixel)
            .disabled(engine.isGenerating)
        }
    }

    private var statusPill: some View {
        Label(engine.statusText, systemImage: engine.isEnabled ? "sun.horizon.fill" : "power")
            .font(.system(.caption, design: .rounded, weight: .bold))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(engine.isEnabled ? ArcaTheme.pixel.opacity(0.18) : .white.opacity(0.08), in: Capsule())
            .foregroundStyle(engine.screenCaptureNeedsPermission ? .orange : .white.opacity(0.86))
    }

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("타임라인", icon: "chart.bar.xaxis")
            if topSummaries.isEmpty {
                emptyLine("아직 오늘 기록된 앱 전환이 없습니다.")
            } else {
                stackedBar
                VStack(spacing: 8) {
                    ForEach(topSummaries) { item in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(color(for: item))
                                .frame(width: 9, height: 9)
                            Text(item.appName)
                                .font(.system(.callout, design: .rounded, weight: .semibold))
                            Spacer()
                            Text("\(item.minutes)분")
                                .foregroundStyle(.white.opacity(0.62))
                            Text(item.lastActiveAt, format: .dateTime.hour().minute())
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .font(.caption)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private var stackedBar: some View {
        let total = max(topSummaries.reduce(0) { $0 + $1.seconds }, 1)
        return GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(topSummaries) { item in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color(for: item))
                        .frame(width: max(3, proxy.size.width * item.seconds / total))
                }
            }
        }
        .frame(height: 18)
    }

    private var snapshotsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("스냅샷", icon: "rectangle.on.rectangle")
                Spacer()
                Text("\(engine.todaySnapshots.count)장")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            if engine.todaySnapshots.isEmpty {
                emptyLine(engine.screenCaptureNeedsPermission ? "화면 기록 권한 필요" : "아직 저장된 스냅샷이 없습니다.")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(engine.todaySnapshots.suffix(6)), id: \.path) { url in
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .scaledToFill()
                                default:
                                    Rectangle().fill(.white.opacity(0.08))
                                }
                            }
                            .frame(width: 138, height: 86)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            Text("로컬에만 저장 · 14일 후 자동 삭제")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    private var pastDigestsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("지난 하루 정리", icon: "clock.arrow.circlepath")
            if digests.isEmpty {
                emptyLine("아직 저장된 하루 정리가 없습니다.")
            } else {
                VStack(spacing: 8) {
                    ForEach(digests.prefix(12)) { session in
                        Button {
                            onOpenSession(session)
                        } label: {
                            HStack {
                                Image(systemName: "sun.horizon.fill")
                                    .foregroundStyle(ArcaTheme.pixel)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(session.title)
                                        .font(.system(.callout, design: .rounded, weight: .semibold))
                                        .lineLimit(1)
                                    Text(session.createdAt, format: .dateTime.month().day().hour().minute())
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.42))
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white.opacity(0.35))
                            }
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(.headline, design: .rounded, weight: .bold))
            .foregroundStyle(.white)
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.system(.callout, design: .rounded))
            .foregroundStyle(.white.opacity(0.48))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
    }

    private func color(for item: DayLogAppSummary) -> Color {
        let index = abs(item.bundleId.unicodeScalars.map { Int($0.value) }.reduce(0, +)) % palette.count
        return palette[index]
    }
}
#endif
