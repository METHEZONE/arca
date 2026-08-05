import SwiftUI
import SwiftData
import UserNotifications
import ArcaVoiceKit

/// The reason to open ARCA today.
///
/// Everything on it is already known by the time the user wakes up: last night's
/// sleep came in with the Watch, the golden window comes from weeks of observed
/// focus, the ledger from ZONE sessions, and the open items from the task store.
/// None of it needs the user to do anything first — which is the point. A daily
/// surface that asks you to fill it in is a chore, not a habit.
struct MorningMomentCard: View {
    @State private var vitals = VitalsEngine.shared
    @State private var services = AppServices.shared
    @Query private var openTasks: [TodoTask]

    /// Tapped to open the full 컨디션 surface.
    var onOpenCondition: (() -> Void)?

    init(onOpenCondition: (() -> Void)? = nil) {
        self.onOpenCondition = onOpenCondition
        // Anything not finished and not thrown away still counts as on the plate.
        _openTasks = Query(filter: #Predicate<TodoTask> {
            $0.stateRaw != "done" && $0.stateRaw != "trashed"
        })
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let name = services.ownerDisplayName
        switch hour {
        case 5..<11: return L("좋은 아침이에요, \(name)", "Good morning, \(name)")
        case 11..<17: return L("좋은 오후예요, \(name)", "Good afternoon, \(name)")
        case 17..<22: return L("좋은 저녁이에요, \(name)", "Good evening, \(name)")
        default: return L("고요한 밤이에요, \(name)", "Quiet night, \(name)")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ArcaSpacing.md) {
            HStack(alignment: .top, spacing: ArcaSpacing.md) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(greeting)
                        .font(.system(.headline, design: .rounded, weight: .bold))
                    Text(headline)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    onOpenCondition?()
                } label: {
                    ZStack {
                        FocusRing(score: vitals.ringScore, isLive: vitals.ringIsLive,
                                  lineWidth: 5, trackOpacity: 0.10)
                            .frame(width: 46, height: 46)
                        Text(vitals.ringScore.map(String.init) ?? "—")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                    }
                }
                .buttonStyle(.arcaPress)
                .disabled(onOpenCondition == nil)
            }

            Divider().overlay(.white.opacity(0.07))

            VStack(alignment: .leading, spacing: 7) {
                ForEach(lines, id: \.text) { line in
                    HStack(spacing: 8) {
                        Image(systemName: line.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(line.tint)
                            .frame(width: 15)
                        Text(line.text)
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.white.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(ArcaSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: ArcaRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: ArcaRadius.lg).strokeBorder(.white.opacity(0.06)))
    }

    /// One sentence naming today's most useful fact. Ordered by what would
    /// actually change the user's next hour.
    private var headline: String {
        if let next = vitals.nextFocusWindow() {
            return L("가장 어려운 일은 \(next.label)에 넣으세요.",
                     "Put the hardest thing in \(next.label).")
        }
        if let readiness = vitals.today?.scores.readiness {
            return VitalsScoring.readinessLabel(readiness)
        }
        return L("워치를 차고 하루만 지내면 오늘의 리듬을 알려드릴 수 있어요.",
                 "Wear your Watch for a day and I can tell you your rhythm.")
    }

    private struct Line {
        var symbol: String
        var text: String
        var tint: Color
    }

    private var lines: [Line] {
        var result: [Line] = []

        if let sleep = vitals.today?.metrics.sleep, sleep.asleepMinutes > 0 {
            let score = vitals.today?.scores.sleep
            result.append(Line(
                symbol: "bed.double.fill",
                text: L("어젯밤 \(sleep.durationLabel)\(score.map { " · 수면 점수 \($0)" } ?? "")",
                        "Slept \(sleep.durationLabel)\(score.map { " · score \($0)" } ?? "")"),
                tint: FocusRing.tint(for: score)))
        }

        if let stress = vitals.today?.scores.stress {
            result.append(Line(
                symbol: "waveform.path.ecg",
                text: L("스트레스 \(stress) · \(VitalsScoring.stressLabel(stress))",
                        "Stress \(stress) · \(VitalsScoring.stressLabel(stress))"),
                tint: FocusRing.stressTint(for: stress)))
        }

        let recovered = vitals.ledger.current
        if recovered.zoneMinutes > 0 {
            result.append(Line(
                symbol: "hourglass",
                text: L("이번 주 ZONE \(VitalsFormat.hoursMinutes(recovered.zoneMinutes)) · ARCA가 방해 \(recovered.absorbed)건을 막았어요",
                        "\(VitalsFormat.hoursMinutes(recovered.zoneMinutes)) in the ZONE this week · ARCA absorbed \(recovered.absorbed)"),
                tint: ArcaTheme.pixel))
        }

        if !openTasks.isEmpty {
            result.append(Line(
                symbol: "checklist",
                text: L("아직 \(openTasks.count)개가 남아 있어요",
                        "\(openTasks.count) still open"),
                tint: .white.opacity(0.6)))
        }

        return result
    }
}

/// The weekly "here's what I actually did for you" card.
///
/// It reports two facts and refuses to invent a third. The tempting headline is
/// "ARCA saved you N hours" — that needs a cost-per-interruption constant that
/// doesn't honestly exist, so this shows the focus time and the absorbed count
/// separately and lets them speak for themselves.
struct RecoveredTimeCard: View {
    @State private var vitals = VitalsEngine.shared

    private var trend: FocusLedgerTrend { vitals.ledger }
    private var ledger: FocusLedger { trend.current }

    var body: some View {
        VStack(alignment: .leading, spacing: ArcaSpacing.md) {
            Label(L("ARCA가 해낸 것", "What ARCA did"), systemImage: "shield.lefthalf.filled")
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))

            if ledger.isEmpty {
                Text(L("ZONE을 한 번 켜보면 여기에 되찾은 시간이 쌓여요.",
                       "Turn on the ZONE once and the time you got back shows up here."))
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(VitalsFormat.hoursMinutes(ledger.zoneMinutes))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(ArcaTheme.pixel)
                    Text(L("이번 주 몰입", "in the ZONE this week"))
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer(minLength: 0)
                    if trend.hasComparison {
                        deltaChip
                    }
                }

                HStack(spacing: ArcaSpacing.lg) {
                    stat(L("ARCA가 막음", "Absorbed"), "\(ledger.absorbed)", ArcaTheme.pixel)
                    stat(L("당신이 판단", "Needed you"), "\(ledger.escalated)",
                         ledger.escalated > 0 ? .orange : .white.opacity(0.6))
                    if ledger.loopsClosed > 0 {
                        stat(L("닫은 루프", "Loops closed"), "\(ledger.loopsClosed)",
                             .white.opacity(0.75))
                    }
                }

                if let rate = ledger.absorbRate {
                    Text(L("들어온 것 중 \(Int(rate * 100))%를 ARCA가 대신 처리했어요.",
                           "ARCA handled \(Int(rate * 100))% of what came in."))
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let best = ledger.bestDay {
                    Text(L("가장 깊었던 날 \(best.day) · \(VitalsFormat.hoursMinutes(best.minutes))",
                           "Deepest day \(best.day) · \(VitalsFormat.hoursMinutes(best.minutes))"))
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.white.opacity(0.32))
                }
            }
        }
        .padding(ArcaSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: ArcaRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: ArcaRadius.lg).strokeBorder(.white.opacity(0.05)))
    }

    private var deltaChip: some View {
        let up = trend.isImproving
        let percent = trend.minutesDeltaPercent
        return HStack(spacing: 3) {
            Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 9, weight: .bold))
            Text(percent.map { "\(abs($0))%" }
                 ?? VitalsFormat.hoursMinutes(abs(trend.minutesDelta)))
                .font(.system(size: 10, weight: .bold, design: .rounded))
        }
        .foregroundStyle(up ? ArcaTheme.pixel : .orange)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background((up ? ArcaTheme.pixel : Color.orange).opacity(0.14), in: Capsule())
        .help(L("지난주 대비", "vs. last week"))
    }

    private func stat(_ title: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
        }
    }
}

/// Schedules the daily morning brief.
///
/// Opt-in and off by default: an unrequested daily notification is the fastest
/// way to get an app muted, and the card itself already works for anyone who
/// opens ARCA on their own.
@MainActor
enum MorningNotifier {
    static let enabledKey = "morningBriefEnabled"
    static let hourKey = "morningBriefHour"
    private static let identifier = "arca-morning-brief"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var hour: Int { UserDefaults.standard.object(forKey: hourKey) as? Int ?? 8 }

    /// Called on launch and whenever the setting changes.
    static func reschedule() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        guard isEnabled else { return }

        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            break
        case .notDetermined:
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
                // Denied at the prompt — turn the setting back off rather than
                // leaving a toggle on that silently does nothing.
                UserDefaults.standard.set(false, forKey: enabledKey)
                return
            }
        default:
            UserDefaults.standard.set(false, forKey: enabledKey)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = L("오늘의 ARCA", "ARCA today")
        content.body = body()
        content.sound = .default

        var components = DateComponents()
        components.hour = hour
        components.minute = 0
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true))
        try? await center.add(request)
    }

    /// The line the notification carries. Built from what's already measured, and
    /// deliberately specific — "좋은 아침이에요" alone earns a swipe-away.
    private static func body() -> String {
        let vitals = VitalsEngine.shared
        if let next = vitals.nextFocusWindow(), let readiness = vitals.today?.scores.readiness {
            return L("준비도 \(readiness) · 가장 어려운 일은 \(next.label)에.",
                     "Readiness \(readiness) · put the hardest thing in \(next.label).")
        }
        if let next = vitals.nextFocusWindow() {
            return L("오늘 \(next.label)이 가장 깊어지는 시간이에요.",
                     "\(next.label) is when you go deepest.")
        }
        if let readiness = vitals.today?.scores.readiness {
            return L("오늘 준비도 \(readiness) · \(VitalsScoring.readinessLabel(readiness))",
                     "Readiness \(readiness) · \(VitalsScoring.readinessLabel(readiness))")
        }
        return L("어젯밤 기록을 확인해 볼까요?", "Shall we look at last night?")
    }
}
