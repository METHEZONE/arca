import SwiftUI
import SwiftData
import ArcaVoiceKit

/// 하루 — where the day's time actually went.
///
/// Cross-platform, but honestly asymmetric: the app-switch timeline and the
/// screen snapshots can only be recorded on the Mac, so the iPhone shows the
/// finished day digests that came through the relay and says where they were
/// made. Hiding the whole section on the phone is what made the two apps feel
/// like different products.
struct DayLogView: View {
    @Query(filter: #Predicate<RecordingSession> { $0.sourceRaw == "dayLog" },
           sort: \RecordingSession.createdAt,
           order: .reverse)
    private var digests: [RecordingSession]

    let onOpenSession: (RecordingSession) -> Void

    #if os(macOS)
    @State private var services = AppServices.shared
    @Environment(\.modelContext) private var modelContext
    private var engine: DayLogEngine { services.dayLog }
    private var topSummaries: [DayLogAppSummary] { Array(engine.todaySummaries.prefix(8)) }
    #endif

    private var palette: [Color] { ArcaTheme.speakerColors }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                #if os(macOS)
                if let status = engine.statusMessage {
                    Label(status, systemImage: "info.circle")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.orange)
                }
                timelineSection
                snapshotsSection
                #else
                recordedOnMacNote
                #endif
                pastDigestsSection
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(ArcaTheme.spiritNight)
        #if os(macOS)
        .onAppear {
            engine.applySettings()
            engine.reloadToday()
        }
        #endif
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Date.now, format: .dateTime.year().month().day().weekday())
                    .font(.system(.title2, design: .rounded, weight: .bold))
                #if os(macOS)
                HStack(spacing: 8) {
                    statusPill
                    if !engine.isEnabled {
                        Button(L("켜기", "Turn on")) { engine.setEnabled(true) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
                #endif
            }
            Spacer()
            #if os(macOS)
            Button {
                Task {
                    if let session = await engine.generateTodayDigest(context: modelContext) {
                        onOpenSession(session)
                    }
                }
            } label: {
                Label(engine.isGenerating ? L("정리 중", "Wrapping up") : L("오늘 정리하기", "Wrap up today"),
                      systemImage: engine.isGenerating ? "hourglass" : "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .tint(ArcaTheme.pixel)
            .disabled(engine.isGenerating)
            #endif
        }
    }

    #if os(macOS)
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
            sectionTitle(L("타임라인", "Timeline"), icon: "chart.bar.xaxis")
            if topSummaries.isEmpty {
                emptyLine(L("아직 오늘 기록된 앱 전환이 없습니다.", "No app switches recorded today yet."))
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
                            Text(L("\(item.minutes)분", "\(item.minutes) min"))
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
                sectionTitle(L("스냅샷", "Snapshots"), icon: "rectangle.on.rectangle")
                Spacer()
                Text(L("\(engine.todaySnapshots.count)장",
                       engine.todaySnapshots.count == 1
                           ? "1 shot"
                           : "\(engine.todaySnapshots.count) shots"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            if engine.todaySnapshots.isEmpty {
                emptyLine(engine.screenCaptureNeedsPermission
                          ? L("화면 기록 권한 필요", "Screen Recording permission needed")
                          : L("아직 저장된 스냅샷이 없습니다.", "No snapshots saved yet."))
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
            Text(L("이 맥에만 저장 · 14일 후 자동 삭제",
                   "Kept on this Mac only · deleted automatically after 14 days"))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
        }
    }
    #else

    /// The iPhone's honest version of the two sections it can't have. Naming the
    /// reason, and what does arrive, is the difference between "one app that
    /// spans my devices" and "the Mac app has more stuff".
    private var recordedOnMacNote: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("타임라인과 스냅샷은 맥이 기록해요", "Your Mac records the timeline and snapshots"),
                  systemImage: "laptopcomputer")
                .font(.system(.callout, design: .rounded, weight: .bold))
            Text(L("어떤 앱에 얼마나 있었는지, 화면이 어땠는지는 맥에서만 볼 수 있는 것들이라 맥 ARCA가 기록합니다. 하루가 끝나면 정리해서 아래로 보내줘요 — 그건 여기서도 그대로 읽을 수 있습니다.",
                   "Which apps you spent time in and what your screen looked like are things only the Mac can see, so ARCA on the Mac records them. When the day ends it wraps everything up and sends it down here — and that you can read in full."))
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
            DevicePresenceBar(compact: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: ArcaRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: ArcaRadius.lg).strokeBorder(.white.opacity(0.06)))
    }
    #endif

    // MARK: - Shared

    private var pastDigestsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(L("지난 하루 정리", "Past daily wrap-ups"), icon: "clock.arrow.circlepath")
            if digests.isEmpty {
                emptyLine(Self.emptyDigestLine)
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
                        .buttonStyle(.arcaPress)
                    }
                }
            }
        }
    }

    private static var emptyDigestLine: String {
        #if os(macOS)
        return L("아직 저장된 하루 정리가 없습니다.", "No daily wrap-ups saved yet.")
        #else
        return L("아직 도착한 하루 정리가 없어요. 맥 ARCA에서 하루가 정리되면 여기로 들어옵니다.",
                 "No daily wrap-ups have arrived yet. Once ARCA on your Mac wraps up a day, it shows up here.")
        #endif
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
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 10)
    }

    #if os(macOS)
    private func color(for item: DayLogAppSummary) -> Color {
        let index = abs(item.bundleId.unicodeScalars.map { Int($0.value) }.reduce(0, +)) % palette.count
        return palette[index]
    }
    #endif
}
