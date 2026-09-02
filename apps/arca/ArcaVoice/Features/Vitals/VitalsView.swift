import SwiftUI
import ArcaVoiceKit

/// The 컨디션 screen — one surface for both platforms, because the iPhone and the
/// Mac are showing the same day from the same relayed file and there's no reason
/// for them to disagree about how it looks.
///
/// Everything on it is measured or absent. Where a number is missing the screen
/// says why and what to do about it, instead of rendering a plausible zero.
struct VitalsView: View {
    @State private var vitals = VitalsEngine.shared
    @State private var measureSeconds = 180

    private var today: DailyVitals? { vitals.today }
    private var scores: VitalsScores { today?.scores ?? VitalsScores() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ArcaSpacing.lg) {
                if vitals.needsPermissionPrompt {
                    permissionCard
                }
                if !vitals.isEnabled {
                    disabledCard
                }
                #if os(macOS)
                phoneLinkCard
                #endif
                hero
                statRow
                RecoveredTimeCard()
                measureCard
                focusProfileCard
                sleepCard
                mealsCard
                coachCard
                if let message = vitals.statusMessage {
                    statusCard(message)
                }
                footnote
            }
            .padding(ArcaSpacing.xl)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(ArcaTheme.spiritNight.ignoresSafeArea())
        .foregroundStyle(.white)
        .task { await vitals.refresh() }
        .refreshable { await vitals.refresh(force: true) }
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .center, spacing: ArcaSpacing.xl) {
            ZStack {
                FocusRing(score: vitals.ringScore, isLive: vitals.ringIsLive, lineWidth: 12)
                    .frame(width: 132, height: 132)
                VStack(spacing: 0) {
                    Text(vitals.ringScore.map(String.init) ?? "—")
                        .font(.system(size: 42, weight: .black, design: .rounded))
                        .contentTransition(.numericText())
                    Text(vitals.ringIsLive ? L("몰입 깊이", "Focus depth") : L("몰입 준비도", "Readiness"))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(vitals.ringLabel)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                if scores.drivers.isEmpty {
                    Text(L("워치를 차고 하루만 지내면 여기에 근거가 채워져요.",
                           "Wear your watch for a day and the reasons fill in here."))
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                } else {
                    ForEach(scores.drivers, id: \.self) { driver in
                        HStack(alignment: .top, spacing: 6) {
                            Circle().fill(.white.opacity(0.3))
                                .frame(width: 3, height: 3).padding(.top, 6)
                            Text(driver)
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(.white.opacity(0.72))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let at = vitals.lastRefreshAt {
                    (ArcaLanguage.isKorean
                        ? Text("업데이트 \(at, style: .relative) 전")
                        : Text("Updated \(at, style: .relative) ago"))
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(ArcaSpacing.lg)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: ArcaRadius.lg))
    }

    private var statRow: some View {
        HStack(spacing: ArcaSpacing.sm) {
            VitalsStatTile(title: L("준비도", "Readiness"), score: scores.readiness,
                           caption: VitalsScoring.readinessLabel(scores.readiness),
                           tint: FocusRing.tint(for: scores.readiness),
                           systemImage: "bolt.heart")
            VitalsStatTile(title: L("스트레스", "Stress"), score: scores.stress,
                           caption: VitalsScoring.stressLabel(scores.stress),
                           tint: FocusRing.stressTint(for: scores.stress),
                           systemImage: "waveform.path.ecg")
            VitalsStatTile(title: L("수면", "Sleep"), score: scores.sleep,
                           caption: VitalsScoring.sleepLabel(scores.sleep),
                           tint: FocusRing.tint(for: scores.sleep),
                           systemImage: "moon.zzz")
        }
    }

    // MARK: - Deep measure

    private var measureCard: some View {
        card(L("지금 몰입 측정", "Measure focus now"), systemImage: "target") {
            VStack(alignment: .leading, spacing: ArcaSpacing.md) {
                Text(L("애플워치로 \(measureSeconds / 60)분간 심박을 직접 재서 지금 얼마나 깊이 들어갔는지 봅니다. 평소에는 아무것도 측정하지 않으니 배터리를 먹지 않아요.",
                       "Your Apple Watch reads your heart for \(measureSeconds / 60) \(measureSeconds == 60 ? "minute" : "minutes") to see how deep you are right now. Nothing is measured the rest of the time, so it won’t eat your battery."))
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))

                Picker(L("측정 시간", "Measurement length"), selection: $measureSeconds) {
                    Text(L("1분", "1 min")).tag(60)
                    Text(L("3분", "3 min")).tag(180)
                    Text(L("5분", "5 min")).tag(300)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                #if os(iOS)
                Button {
                    startMeasure()
                } label: {
                    Label(vitals.isMeasuring ? L("측정 중…", "Measuring…")
                                            : L("애플워치에서 측정 시작", "Start on Apple Watch"),
                          systemImage: vitals.isMeasuring ? "waveform" : "applewatch.radiowaves.left.and.right")
                        .font(.system(.callout, design: .rounded, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(vitals.isMeasuring ? .white.opacity(0.12) : ArcaTheme.pixel.opacity(0.85),
                                    in: Capsule())
                        .foregroundStyle(vitals.isMeasuring ? .white.opacity(0.7) : .black)
                }
                .buttonStyle(.arcaPress)
                .disabled(vitals.isMeasuring)
                #else
                Text(L("측정은 애플워치의 ARCA에서 시작해요 — 워치 화면을 아래로 넘겨 ‘몰입 측정’을 누르면 됩니다. 결과는 아이폰을 거쳐 여기로 들어옵니다.",
                       "Start a measurement from ARCA on your Apple Watch — swipe down and tap ‘Measure focus’. The result comes here by way of your iPhone."))
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                #endif

                if let latest = latestMeasure {
                    Divider().overlay(.white.opacity(0.08))
                    HStack(spacing: ArcaSpacing.md) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(latest.focusDepth)")
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                                .foregroundStyle(FocusRing.tint(for: latest.focusDepth))
                            Text(VitalsScoring.focusDepthLabel(latest.focusDepth))
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            (ArcaLanguage.isKorean
                                ? Text("\(latest.startedAt, style: .time) · \(latest.seconds / 60)분 측정")
                                : Text("\(latest.startedAt, style: .time) · \(latest.seconds / 60) min session"))
                                .font(.system(.caption2, design: .rounded, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.7))
                            Text(L("평균 \(Int(latest.meanHR))bpm (\(Int(latest.minHR))–\(Int(latest.maxHR)))",
                                   "Avg \(Int(latest.meanHR))bpm (\(Int(latest.minHR))–\(Int(latest.maxHR)))"))
                                .font(.system(.caption2, design: .rounded))
                                .foregroundStyle(.white.opacity(0.5))
                            if let sdnn = latest.hrvSDNN {
                                Text("HRV \(Int(sdnn))ms")
                                    .font(.system(.caption2, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.5))
                            } else if latest.beatIntervalSD != nil {
                                Text(L("심박 변동 추정치 사용 — 워치가 이 구간에 HRV를 쓰지 않았어요",
                                       "Using an estimated beat variation — the Watch didn’t record HRV for this stretch"))
                                    .font(.system(size: 9, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.35))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var latestMeasure: DeepMeasure? {
        today?.deepMeasures.max { $0.startedAt < $1.startedAt }
    }

    #if os(iOS)
    private func startMeasure() {
        vitals.beginMeasuring()
        guard PhoneWatchSync.shared.requestDeepMeasure(seconds: measureSeconds) else {
            vitals.failMeasuring(L("애플워치가 닿지 않아요 — 워치에서 ARCA를 열고 ‘몰입 측정’을 눌러주세요.",
                                   "Your Apple Watch isn’t reachable — open ARCA on the watch and tap ‘Measure focus’."))
            return
        }
    }
    #endif

    // MARK: - Focus profile

    private var focusProfileCard: some View {
        card(L("몰입 골든타임", "Your golden hours"), systemImage: "clock.badge.checkmark") {
            VStack(alignment: .leading, spacing: ArcaSpacing.md) {
                Text(vitals.focusNarrative)
                    .font(.system(.callout, design: .rounded, weight: .semibold))

                // Answered back in the same four words the onboarding asked in.
                if let bucket = vitals.focusBucket {
                    Label(bucket.label, systemImage: "person.fill.checkmark")
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.62))
                }

                if vitals.focusWindows.isEmpty {
                    Text(L("맥에서 실제로 몰입한 구간(앱을 오래 붙잡고 있던 시간, ZONE 세션)이 3시간쯤 쌓이면 시간대 프로필이 만들어져요.",
                           "Once about three hours of real focus stack up on your Mac (long stretches in one app, ZONE sessions), ARCA builds your hour-by-hour profile."))
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    FocusWindowChart(windows: vitals.focusWindows,
                                     highlightHour: vitals.nextFocusWindow()?.hour)
                    if let next = vitals.nextFocusWindow() {
                        Label(L("다음 골든타임 \(next.label) — 여기에 가장 어려운 일을 넣으세요",
                                "Next golden hour \(next.label) — put your hardest work here"),
                              systemImage: "arrow.right.circle.fill")
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .foregroundStyle(ArcaTheme.pixel)
                    }
                    let observed = vitals.focusWindows.reduce(0) { $0 + $1.minutesObserved }
                    Text(L("관측된 몰입 시간 총 \(VitalsFormat.hoursMinutes(observed)) 기준",
                           "Based on \(VitalsFormat.hoursMinutes(observed)) of observed focus"))
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
        }
    }

    // MARK: - Sleep

    private var sleepCard: some View {
        card(L("어젯밤", "Last night"), systemImage: "bed.double") {
            if let sleep = today?.metrics.sleep, sleep.asleepMinutes > 0 {
                VStack(alignment: .leading, spacing: ArcaSpacing.md) {
                    HStack(alignment: .firstTextBaseline, spacing: ArcaSpacing.md) {
                        Text(sleep.durationLabel)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                        if let bedtime = sleep.bedtime, let wake = sleep.wakeTime {
                            Text("\(bedtime, style: .time) → \(wake, style: .time)")
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer(minLength: 0)
                    }

                    if sleep.hasStages {
                        stageBars(sleep)
                        HStack(spacing: ArcaSpacing.md) {
                            stageLegend(L("깊은 수면", "Deep"), sleep.deepMinutes)
                            stageLegend("REM", sleep.remMinutes)
                            stageLegend(L("코어", "Core"), sleep.coreMinutes)
                            if sleep.awakenings > 0 {
                                stageLegend(L("깬 횟수", "Awakenings"), sleep.awakenings, isCount: true)
                            }
                        }
                    } else {
                        Text(L("이 기기는 수면 단계를 나누지 못했어요 — 깊은 수면·REM 비중은 애플워치를 차고 자면 잡힙니다. 점수는 시간과 연속성만으로 계산했어요.",
                               "This device couldn’t split your sleep into stages — deep sleep and REM show up when you sleep with your Apple Watch on. This score comes from duration and continuity alone."))
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text(L("어젯밤 수면 기록이 없어요. 애플워치를 차고 자면 다음 날 아침 여기에 들어옵니다.",
                       "No sleep recorded last night. Sleep with your Apple Watch on and it lands here the next morning."))
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private struct StageSegment: Identifiable {
        var id: String { label }
        var label: String
        var minutes: Int
        var color: Color
    }

    private func stageSegments(_ sleep: SleepSummary) -> [StageSegment] {
        [
            StageSegment(label: L("깊은 수면", "Deep"), minutes: sleep.deepMinutes,
                         color: Color(red: 0.34, green: 0.42, blue: 0.95)),
            StageSegment(label: "REM", minutes: sleep.remMinutes,
                         color: Color(red: 0.42, green: 0.78, blue: 0.95)),
            StageSegment(label: L("코어", "Core"), minutes: sleep.coreMinutes,
                         color: Color(red: 0.30, green: 0.58, blue: 0.78)),
        ].filter { $0.minutes > 0 }
    }

    /// Proportional stage bar. Widths are computed against the measured width
    /// minus the gaps — `layoutPriority` does not give proportional sizing, it
    /// only decides who gets squeezed first.
    private func stageBars(_ sleep: SleepSummary) -> some View {
        let segments = stageSegments(sleep)
        let total = Double(max(1, segments.reduce(0) { $0 + $1.minutes }))
        let gap: CGFloat = 3
        return GeometryReader { proxy in
            let available = max(0, proxy.size.width - gap * CGFloat(max(0, segments.count - 1)))
            HStack(spacing: gap) {
                ForEach(segments) { segment in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(segment.color)
                        .frame(width: max(2, available * (Double(segment.minutes) / total)))
                        .accessibilityLabel(Text(L("\(segment.label) \(segment.minutes)분",
                                                   "\(segment.label) \(segment.minutes) min")))
                }
            }
        }
        .frame(height: 10)
    }

    private func stageLegend(_ label: String, _ value: Int, isCount: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
            Text(isCount ? L("\(value)회", "\(value)") : VitalsFormat.hoursMinutes(value))
                .font(.system(.caption2, design: .rounded, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    // MARK: - Meals

    private var mealsCard: some View {
        card(L("오늘 먹은 것", "What you ate today"), systemImage: "fork.knife") {
            VStack(alignment: .leading, spacing: ArcaSpacing.md) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(healthCalories ?? today?.loggedCalories ?? 0))")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("kcal")
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                    if let burned = today?.metrics.totalEnergyKcal, burned > 0 {
                        Text(L("· 소모 \(Int(burned))kcal", "· \(Int(burned))kcal burned"))
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer(minLength: 0)
                }

                if let meals = today?.meals, !meals.isEmpty {
                    ForEach(meals) { meal in
                        HStack(alignment: .top, spacing: ArcaSpacing.sm) {
                            Text(meal.at, style: .time)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4))
                                .frame(width: 44, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(meal.label)
                                    .font(.system(.callout, design: .rounded, weight: .semibold))
                                Text(macroLine(meal))
                                    .font(.system(size: 10, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.45))
                            }
                            Spacer(minLength: 0)
                            if !meal.writtenToHealth {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.caption2)
                                    .foregroundStyle(.orange.opacity(0.8))
                                    .help(L("애플 건강에는 아직 안 들어갔어요 — 아이폰이 다음 동기화에 씁니다",
                                            "Not in Apple Health yet — your iPhone writes it on the next sync"))
                            }
                        }
                    }
                }

                Text(L("말로 기록하는 게 제일 편해요 — 챗에서 “점심 김치찌개 먹었어”라고만 하면 ARCA가 칼로리를 추정해서 애플 건강까지 넣습니다.",
                       "Just saying it is easiest — tell ARCA “had kimchi stew for lunch” in chat and it estimates the calories and files them into Apple Health."))
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Apple Health's own total includes food logged in other apps, so it beats
    /// ARCA's private tally when it exists.
    private var healthCalories: Double? {
        guard let value = today?.metrics.dietaryEnergyKcal, value > 0 else { return nil }
        return value
    }

    private func macroLine(_ meal: MealEntry) -> String {
        var parts = ["\(Int(meal.calories))kcal"]
        if let protein = meal.proteinGrams {
            parts.append(L("단백 \(Int(protein))g", "Protein \(Int(protein))g"))
        }
        if let carbs = meal.carbsGrams {
            parts.append(L("탄수 \(Int(carbs))g", "Carbs \(Int(carbs))g"))
        }
        if let fat = meal.fatGrams {
            parts.append(L("지방 \(Int(fat))g", "Fat \(Int(fat))g"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Coach

    private var coachCard: some View {
        card(L("ARCA의 조언", "ARCA’s advice"), systemImage: "sparkles") {
            VStack(alignment: .leading, spacing: ArcaSpacing.md) {
                if let coach = vitals.coach {
                    Text(coach.headline)
                        .font(.system(.callout, design: .rounded, weight: .bold))
                    adviceList(L("수면", "Sleep"), coach.sleepAdvice)
                    adviceList(L("몰입", "Focus"), coach.focusAdvice)
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "star.fill")
                            .font(.caption2).foregroundStyle(ArcaTheme.pixel)
                        Text(coach.oneThing)
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(ArcaSpacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ArcaTheme.pixel.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: ArcaRadius.sm))
                    (ArcaLanguage.isKorean
                        ? Text("\(coach.generatedAt, style: .relative) 전에 만든 조언")
                        : Text("Advice written \(coach.generatedAt, style: .relative) ago"))
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.white.opacity(0.3))
                } else {
                    Text(L("며칠치 기록이 모이면 수면을 어떻게 고칠지, 몰입을 언제 배치할지 구체적으로 짚어줄 수 있어요.",
                           "Once a few days of records add up, ARCA can tell you exactly what to fix about your sleep and when to place your focus."))
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    Task { await vitals.runCoach() }
                } label: {
                    Label(vitals.isCoaching ? L("읽고 있어요…", "Reading you…")
                                            : L("지금 조언 받기", "Get advice now"),
                          systemImage: vitals.isCoaching ? "hourglass" : "wand.and.stars")
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .padding(.horizontal, ArcaSpacing.lg)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.arcaPress)
                .disabled(vitals.isCoaching)
            }
        }
    }

    private func adviceList(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if !items.isEmpty {
                Text(title)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Circle().fill(.white.opacity(0.28))
                            .frame(width: 3, height: 3).padding(.top, 6)
                        Text(item)
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.white.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Notices

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: ArcaSpacing.md) {
            Label(L("Apple 건강 권한이 필요해요", "ARCA needs Apple Health access"),
                  systemImage: "heart.text.square")
                .font(.system(.callout, design: .rounded, weight: .bold))
            Text(L("수면·심박·HRV·활동을 읽어서 몰입 준비도와 스트레스를 계산합니다. 데이터는 기기 안에 있고, 맥에는 계산된 요약만 넘어갑니다.",
                   "It reads sleep · heart rate · HRV · activity to work out your readiness and stress. The data stays on this device; only the finished summary goes to your Mac."))
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            #if os(iOS)
            Button {
                Task { await vitals.requestPermission() }
            } label: {
                Text(L("건강 권한 허용하기", "Allow Health access"))
                    .font(.system(.callout, design: .rounded, weight: .bold))
                    .padding(.horizontal, ArcaSpacing.xl)
                    .padding(.vertical, 10)
                    .background(ArcaTheme.pixel.opacity(0.9), in: Capsule())
                    .foregroundStyle(.black)
            }
            .buttonStyle(.arcaPress)
            #endif
        }
        .padding(ArcaSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ArcaTheme.pixel.opacity(0.10), in: RoundedRectangle(cornerRadius: ArcaRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: ArcaRadius.lg)
            .strokeBorder(ArcaTheme.pixel.opacity(0.35)))
    }

    private var disabledCard: some View {
        Label(L("바이탈 추적이 꺼져 있어요 — 설정에서 켜면 다시 측정합니다.",
                "Vitals tracking is off — turn it on in Settings and ARCA starts measuring again."),
              systemImage: "pause.circle")
            .font(.system(.caption, design: .rounded, weight: .semibold))
            .foregroundStyle(.orange)
            .padding(ArcaSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: ArcaRadius.md))
    }

    private func statusCard(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.system(.caption, design: .rounded))
            .foregroundStyle(.orange)
            .padding(ArcaSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: ArcaRadius.md))
    }

    #if os(macOS)
    /// The Mac can't read Apple Health; the iPhone does and relays it. This
    /// says, in one card, whether that link is alive and what to do if not —
    /// instead of a dash with no explanation.
    private var phoneLinkCard: some View {
        let phone = DevicePresence.shared.peers.first { $0.device == "iphone" }
        let phoneSeen = phone.map { Date.now.timeIntervalSince($0.lastSeenAt) < 30 * 60 } ?? false
        let link = vitals.healthLink
        let relayed: Date? = { if case .relayed(_, let at) = link { return at }; return nil }()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: relayed != nil ? "heart.text.square.fill" : "iphone.and.arrow.forward")
                    .font(.title3)
                    .foregroundStyle(relayed != nil ? .green : ArcaFace.ember)
                VStack(alignment: .leading, spacing: 2) {
                    Text(relayed != nil ? L("Apple 건강 연결됨", "Apple Health connected")
                                        : L("Apple 건강은 아이폰이 이어줘요", "Apple Health comes through your iPhone"))
                        .font(.system(.headline, design: .rounded))
                    if let relayed {
                        Text(L("아이폰에서 마지막 측정 \(relayed.formatted(.relative(presentation: .named)))",
                               "Last measurement from iPhone \(relayed.formatted(.relative(presentation: .named)))"))
                            .font(.caption).foregroundStyle(.white.opacity(0.55))
                    } else {
                        Text(phoneSeen ? L("아이폰 ARCA는 연결돼 있지만 아직 건강 데이터를 보낸 적이 없어요.",
                                           "Your iPhone's ARCA is connected but hasn't sent health data yet.")
                                       : L("아이폰 ARCA가 아직 이 계정으로 연결되지 않았어요.",
                                           "Your iPhone's ARCA hasn't connected to this account yet."))
                            .font(.caption).foregroundStyle(.white.opacity(0.55))
                    }
                }
                Spacer()
            }
            if relayed == nil {
                VStack(alignment: .leading, spacing: 6) {
                    stepRow(1, L("아이폰에 ARCA 설치 — TestFlight", "Install ARCA on iPhone — TestFlight"),
                            done: phoneSeen, link: URL(string: "https://testflight.apple.com/join/U78MNCxj"))
                    stepRow(2, L("아이폰 ARCA › 컨디션 › Apple 건강 연결 허용", "iPhone ARCA › Condition › allow Apple Health"), done: false, link: nil)
                    stepRow(3, L("같은 계정으로 로그인돼 있는지 확인 (설정 › 계정)", "Make sure both devices use the same account (Settings › Account)"), done: false, link: nil)
                }
                Text(L("허용하면 수면·심박·HRV·걸음·운동이 60초 안에 여기로 들어와요.",
                       "Once allowed, sleep, heart rate, HRV, steps and workouts land here within a minute."))
                    .font(.caption2).foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(ArcaSpacing.lg)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: ArcaRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: ArcaRadius.lg).strokeBorder((relayed != nil ? Color.green : ArcaFace.ember).opacity(0.35)))
    }

    private func stepRow(_ n: Int, _ text: String, done: Bool, link: URL?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                .foregroundStyle(done ? .green : .white.opacity(0.6))
            Text(text).font(.callout)
            if let link {
                Link(L("열기", "Open"), destination: link)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ArcaFace.ember)
            }
            Spacer()
        }
    }
    #endif

    private var footnote: some View {
        Text(L("ARCA는 의료 기기가 아니고 진단을 하지 않아요. 여기 숫자는 애플 건강에 이미 있는 측정값과, 그걸로 계산한 지표입니다.",
               "ARCA is not a medical device and does not diagnose. These numbers are the measurements already in Apple Health, and what ARCA works out from them."))
            .font(.system(size: 10, design: .rounded))
            .foregroundStyle(.white.opacity(0.28))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Card chrome

    private func card<Content: View>(_ title: String, systemImage: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: ArcaSpacing.md) {
            Label(title, systemImage: systemImage)
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
            content()
        }
        .padding(ArcaSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: ArcaRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: ArcaRadius.lg)
            .strokeBorder(.white.opacity(0.05)))
    }
}
