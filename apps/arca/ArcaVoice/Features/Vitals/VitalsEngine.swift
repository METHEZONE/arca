import Foundation
import Observation
import SwiftData
import ArcaVoiceKit
#if os(iOS)
import WidgetKit
#endif

/// The one place the app asks "how is the user's body, and when do they focus?"
///
/// The two platforms know different halves and the split is deliberate:
///
/// - **iPhone** reads Apple Health. This costs no battery — the Watch already
///   wrote that data on its own schedule, so ARCA is only querying a local
///   store. Nothing here turns a sensor on.
/// - **Mac** can't touch HealthKit at all (the framework doesn't exist there),
///   but it's the machine that sees the app-switch timeline and ZONE sessions,
///   so it owns the focus profile.
///
/// Each side writes its half into the same day file and the relay merges them,
/// which is why `DailyVitals.merged(with:)` is field-group-aware rather than
/// last-writer-wins.
@MainActor
@Observable
final class VitalsEngine {
    static let shared = VitalsEngine()

    /// Long enough for stable baselines and a fortnight of coach context.
    static let historyDays = 21

    // MARK: - Observed state

    private(set) var today: DailyVitals?
    /// Oldest → newest, today last. Baselines rely on this ordering.
    private(set) var history: [DailyVitals] = []
    private(set) var focusWindows: [FocusWindow] = []
    /// What ARCA gave back this week, against last week.
    private(set) var ledger = FocusLedgerTrend(current: .empty, previous: .empty)
    private(set) var coach: VitalsCoachResult?
    private(set) var isRefreshing = false
    private(set) var isCoaching = false
    private(set) var isMeasuring = false
    private(set) var statusMessage: String?
    private(set) var lastRefreshAt: Date?
    /// iPhone only: the Health permission sheet hasn't been shown yet.
    private(set) var needsPermission = false

    // MARK: - Settings (mirrored for observation, DayLogEngine's pattern)

    private(set) var isEnabled = true
    private(set) var pollMinutes = 10
    private(set) var writeToHealth = true
    private(set) var shareToRelay = true

    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Keys {
        static let enabled = "vitalsEnabled"
        static let pollMinutes = "vitalsPollMinutes"
        static let writeToHealth = "vitalsWriteToHealth"
        static let shareToRelay = "vitalsShareToRelay"
    }

    // MARK: - Lifecycle

    func configure() {
        refreshSettings()
        reloadFromDisk()
        coach = VitalsStore.loadCoach()
        Task.detached { VitalsStore.prune() }
        applySettings()
    }

    func applySettings() {
        refreshSettings()
        loopTask?.cancel()
        guard isEnabled else {
            loopTask = nil
            return
        }
        loopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let minutes = max(1, self?.pollMinutes ?? 10)
                try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            }
        }
    }

    private func refreshSettings() {
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        pollMinutes = defaults.object(forKey: Keys.pollMinutes) as? Int ?? 10
        writeToHealth = defaults.object(forKey: Keys.writeToHealth) as? Bool ?? true
        shareToRelay = defaults.object(forKey: Keys.shareToRelay) as? Bool ?? true
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.enabled)
        applySettings()
    }

    // MARK: - Refresh

    /// One measurement pass. Throttled to half the poll interval so scene
    /// activations and the timer can both call it freely.
    func refresh(force: Bool = false, now: Date = .now) async {
        guard isEnabled else { return }
        guard !isRefreshing else { return }
        if !force, let last = lastRefreshAt,
           now.timeIntervalSince(last) < Double(max(1, pollMinutes)) * 30 {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        #if os(iOS)
        await refreshFromHealth(now: now)
        #endif
        #if os(macOS)
        await refreshFocusProfile(now: now)
        #endif

        reloadFromDisk(now: now)
        lastRefreshAt = now
        if shareToRelay { RelaySync.shared.scheduleSync(after: 5) }
    }

    private func reloadFromDisk(now: Date = .now, calendar: Calendar = .current) {
        let days = VitalsStore.recent(days: Self.historyDays, now: now, calendar: calendar)
        history = days
        let todayKey = VitalsFormat.dayKey(for: now, calendar: calendar)
        today = days.last { $0.day == todayKey }
        // The profile is a rolling picture, not a per-day fact: use the most
        // recent day that actually has one, so an iPhone-only day doesn't blank
        // out the windows the Mac computed yesterday.
        focusWindows = days.reversed().first { !$0.focusWindows.isEmpty }?.focusWindows ?? []
        ledger = FocusLedgerBuilder.trend(
            days: days,
            loopsClosedCurrent: closedLoops(within: 7, now: now, calendar: calendar),
            loopsClosedPrevious: closedLoops(within: 14, now: now, calendar: calendar)
                - closedLoops(within: 7, now: now, calendar: calendar))
        publishWidgetSnapshot(now: now)
    }

    /// Tasks ARCA carried to done inside the window — the north-star "closed
    /// loop" count, read from the task store rather than duplicated into vitals.
    private func closedLoops(within days: Int, now: Date, calendar: Calendar) -> Int {
        guard let context = AppServices.shared.container?.mainContext,
              let cutoff = calendar.date(byAdding: .day, value: -days, to: now) else { return 0 }
        let tasks = (try? context.fetch(FetchDescriptor<TodoTask>())) ?? []
        return tasks.filter { $0.state == .done && $0.updatedAt >= cutoff }.count
    }

    /// Hands the widget the handful of numbers a glance needs. Written on every
    /// reload because it's a few hundred bytes; the timeline is only nudged when
    /// something actually changed, so the widget isn't woken for nothing.
    private func publishWidgetSnapshot(now: Date) {
        let snapshot = VitalsSnapshot(
            updatedAt: now,
            ringScore: ringScore,
            isLive: ringIsLive,
            label: ringLabel,
            nextWindowLabel: nextFocusWindow(after: now)?.label,
            sleepMinutes: today?.metrics.sleep?.asleepMinutes,
            stress: today?.scores.stress,
            weeklyZoneMinutes: ledger.current.zoneMinutes,
            weeklyAbsorbed: ledger.current.absorbed)

        guard snapshot != lastPublishedSnapshot else { return }
        lastPublishedSnapshot = snapshot
        VitalsSnapshotStore.write(snapshot)
        #if os(iOS)
        WidgetCenter.shared.reloadTimelines(ofKind: "ArcaVitalsWidget")
        PhoneWatchSync.shared.sendVitalsSummary(
            ringScore: snapshot.ringScore,
            isLive: snapshot.isLive,
            label: snapshot.label,
            nextWindowLabel: snapshot.nextWindowLabel,
            sleepMinutes: snapshot.sleepMinutes)
        #endif
    }

    @ObservationIgnored private var lastPublishedSnapshot: VitalsSnapshot?

    // MARK: - iPhone: Apple Health

    #if os(iOS)
    func requestPermission() async {
        do {
            try await HealthVitals.shared.requestAuthorization()
            needsPermission = false
            statusMessage = nil
            await refresh(force: true)
        } catch {
            statusMessage = UserFacingError.message(for: error)
        }
    }

    private func refreshFromHealth(now: Date, calendar: Calendar = .current) async {
        guard HealthVitals.isAvailable else {
            statusMessage = VitalsError.healthUnavailable.errorDescription
            return
        }
        guard await HealthVitals.shared.hasRequestedAuthorization() else {
            needsPermission = true
            return
        }
        needsPermission = false

        let metricsByDay = await HealthVitals.shared.history(
            days: Self.historyDays, now: now, calendar: calendar)
        guard !metricsByDay.isEmpty else {
            statusMessage = L("Apple 건강에서 읽을 데이터가 없어요. 건강 앱에서 ARCA 권한을 확인해 주세요.",
                              "There’s nothing to read in Apple Health yet. Check ARCA’s permissions in the Health app.")
            return
        }

        // Oldest → newest so each day's baseline only ever sees its own past.
        var priorMetrics: [VitalsMetrics] = []
        for key in metricsByDay.keys.sorted() {
            guard let metrics = metricsByDay[key] else { continue }
            defer { priorMetrics.append(metrics) }

            let stored = VitalsStore.load(day: key)
            let latestMeasure = stored?.deepMeasures.max { $0.startedAt < $1.startedAt }
            let scores = VitalsScoring.evaluate(today: metrics, history: priorMetrics,
                                                latestDeepMeasure: latestMeasure, now: now)
            // Past days stop changing once they're over. Without this guard every
            // pass would rewrite three weeks of files and bump their timestamps,
            // which then looks like a change to the relay.
            guard stored?.metrics != metrics || stored?.scores != scores else { continue }

            VitalsStore.upsert(day: key) { day in
                day.metrics = metrics
                day.scores = scores
                day.device = VitalsDevice.current
                day.updatedAt = now
            }
        }

        await flushPendingHealthWrites(now: now, calendar: calendar)
        statusMessage = nil
    }

    /// Writes meals that were spoken on another device (the Mac can't reach
    /// HealthKit) or that failed their first write. The sticky
    /// `writtenToHealth` flag is what keeps this from double-logging food.
    func flushPendingHealthWrites(now: Date = .now, calendar: Calendar = .current) async {
        guard writeToHealth, await HealthVitals.shared.canWriteFood() else { return }

        for day in VitalsStore.recent(days: 3, now: now, calendar: calendar) {
            let pending = day.pendingHealthWrites
            guard !pending.isEmpty else { continue }

            var written: Set<UUID> = []
            for meal in pending {
                do {
                    try await HealthVitals.shared.write(meal: meal)
                    written.insert(meal.id)
                } catch {
                    NSLog("[ARCA vitals] meal write failed (%@): %@", meal.label, "\(error)")
                }
            }
            guard !written.isEmpty else { continue }
            VitalsStore.upsert(day: day.day) { stored in
                for index in stored.meals.indices where written.contains(stored.meals[index].id) {
                    stored.meals[index].writtenToHealth = true
                }
                stored.updatedAt = now
            }
        }
    }
    #endif

    // MARK: - Mac: focus profile

    #if os(macOS)
    /// Rebuilds the chronotype profile from the Mac's own evidence — the
    /// app-switch timeline plus finished ZONE sessions. File reads and bucketing
    /// happen off the main actor; only the result comes back.
    func refreshFocusProfile(now: Date = .now, calendar: Calendar = .current) async {
        let days = Self.historyDays
        let windows = await Task.detached { () -> [FocusWindow] in
            let sessions = VitalsStore.recent(days: days, now: now, calendar: calendar)
                .flatMap(\.focusSessions)
            let timeline = DayLogEngine.timelineEntries(daysBack: days, now: now, calendar: calendar)
            let evidence = ChronotypeProfile.evidence(fromTimeline: timeline, until: now)
                + ChronotypeProfile.evidence(fromSessions: sessions)
            return ChronotypeProfile.windows(from: evidence, calendar: calendar)
        }.value

        guard !windows.isEmpty else { return }
        let todayKey = VitalsFormat.dayKey(for: now, calendar: calendar)
        guard VitalsStore.load(day: todayKey)?.focusWindows != windows else { return }
        VitalsStore.upsert(day: todayKey) { day in
            day.focusWindows = windows
            day.device = VitalsDevice.current
            day.updatedAt = now
        }
    }
    #endif

    // MARK: - Focus sessions

    /// Records a finished focus session (ZONE). This is the strongest evidence
    /// the profile has, because the user declared the intent and ARCA counted
    /// what still broke through.
    func recordFocusSession(_ session: FocusSession, now: Date = .now, calendar: Calendar = .current) {
        let key = VitalsFormat.dayKey(for: session.startedAt, calendar: calendar)
        VitalsStore.upsert(day: key) { day in
            day.focusSessions.removeAll { $0.id == session.id }
            day.focusSessions.append(session)
            day.focusSessions.sort { $0.startedAt < $1.startedAt }
            day.device = VitalsDevice.current
            day.updatedAt = now
        }
        reloadFromDisk(now: now, calendar: calendar)
        #if os(macOS)
        Task { await self.refreshFocusProfile(now: now, calendar: calendar) }
        #endif
        if shareToRelay { RelaySync.shared.scheduleSync() }
    }

    // MARK: - Deep measure

    /// Takes the raw numbers a Watch measurement produced and scores them here,
    /// where the user's resting-heart-rate baseline actually lives. The Watch
    /// has no history to compare against, so it must not be the one deciding
    /// how deep the session was.
    func recordDeepMeasure(startedAt: Date, seconds: Int, meanHR: Double,
                           minHR: Double, maxHR: Double,
                           hrvSDNN: Double?, beatIntervalSD: Double?,
                           now: Date = .now, calendar: Calendar = .current) {
        let restingHR = today?.metrics.restingHeartRate
        let depth = VitalsScoring.focusDepth(meanHR: meanHR, restingHR: restingHR,
                                             beatIntervalSD: beatIntervalSD)
        let measure = DeepMeasure(startedAt: startedAt, seconds: seconds,
                                  meanHR: meanHR, minHR: minHR, maxHR: maxHR,
                                  hrvSDNN: hrvSDNN, beatIntervalSD: beatIntervalSD,
                                  focusDepth: depth)

        let key = VitalsFormat.dayKey(for: startedAt, calendar: calendar)
        VitalsStore.upsert(day: key) { day in
            day.deepMeasures.removeAll { $0.startedAt == measure.startedAt }
            day.deepMeasures.append(measure)
            day.deepMeasures.sort { $0.startedAt < $1.startedAt }
            day.scores.liveFocus = depth
            day.device = VitalsDevice.current
            day.updatedAt = now
        }
        reloadFromDisk(now: now, calendar: calendar)
        isMeasuring = false
        statusMessage = nil
        if shareToRelay { RelaySync.shared.scheduleSync() }
    }

    func beginMeasuring() { isMeasuring = true }

    func failMeasuring(_ message: String) {
        isMeasuring = false
        statusMessage = message
    }

    // MARK: - Meals

    /// Logs a meal ARCA heard about. On the iPhone it goes straight into Apple
    /// Health; on the Mac it's stored with `writtenToHealth == false` and the
    /// phone writes it on its next pass.
    @discardableResult
    func logMeal(_ draft: MealActionDraft, now: Date = .now,
                 calendar: Calendar = .current) async -> MealEntry? {
        guard draft.isUsable else {
            statusMessage = VitalsError.nothingToWrite.errorDescription
            return nil
        }
        let at = draft.date(now: now, calendar: calendar)
        var entry = MealEntry(at: at, label: draft.label, calories: draft.calories,
                              proteinGrams: draft.proteinGrams, carbsGrams: draft.carbsGrams,
                              fatGrams: draft.fatGrams, note: draft.note,
                              writtenToHealth: false, loggedBy: VitalsDevice.current)

        #if os(iOS)
        if writeToHealth {
            do {
                try await HealthVitals.shared.write(meal: entry)
                entry.writtenToHealth = true
            } catch {
                // Still recorded locally and retried later — a failed Health
                // write must never lose the meal the user just told us about.
                NSLog("[ARCA vitals] health meal write failed: %@", "\(error)")
            }
        }
        #endif

        let key = VitalsFormat.dayKey(for: at, calendar: calendar)
        VitalsStore.upsert(day: key) { day in
            day.meals.append(entry)
            day.meals.sort { $0.at < $1.at }
            day.device = VitalsDevice.current
            day.updatedAt = now
        }
        reloadFromDisk(now: now, calendar: calendar)
        if shareToRelay { RelaySync.shared.scheduleSync() }
        return entry
    }

    func deleteMeal(_ entry: MealEntry, now: Date = .now, calendar: Calendar = .current) {
        // Only ARCA's own record is removed — a sample already in Apple Health
        // stays there, because deleting other apps' health data behind the
        // user's back is not ours to do.
        let key = VitalsFormat.dayKey(for: entry.at, calendar: calendar)
        VitalsStore.upsert(day: key) { day in
            day.meals.removeAll { $0.id == entry.id }
            day.updatedAt = now
        }
        reloadFromDisk(now: now, calendar: calendar)
        if shareToRelay { RelaySync.shared.scheduleSync() }
    }

    // MARK: - Coach

    func runCoach() async {
        guard !isCoaching else { return }
        guard let key = KeychainStore.get(.anthropic), !key.isEmpty else {
            statusMessage = L("Anthropic API 키가 필요해요 — 설정에서 넣어주세요.",
                              "An Anthropic API key is needed — add one in Settings.")
            return
        }
        let measured = history.filter { !$0.metrics.isEmpty }
        guard measured.count >= 3 else {
            statusMessage = L("조언을 만들려면 최소 3일치 기록이 필요해요. 워치를 차고 며칠 지내보세요.",
                              "Advice needs at least three days of records. Wear your watch for a few days and come back.")
            return
        }

        isCoaching = true
        defer { isCoaching = false }
        let model = UserDefaults.standard.string(forKey: "chatModel") ?? "claude-sonnet-5"
        do {
            let result = try await VitalsCoach(apiKey: key, model: model)
                .advise(days: history, windows: focusWindows)
            coach = result
            VitalsStore.save(coach: result)
            statusMessage = nil
        } catch {
            statusMessage = UserFacingError.message(for: error)
        }
    }

    // MARK: - Relay

    /// Applies a day pulled from the relay. `nonisolated` so the sync loop can
    /// merge without hopping to the main actor for every file.
    @discardableResult
    nonisolated static func mergeRelayed(_ remote: DailyVitals) -> Bool {
        let local = VitalsStore.load(day: remote.day)
        let merged = local?.merged(with: remote) ?? remote
        guard merged != local else { return false }
        VitalsStore.save(merged)
        return true
    }

    /// Called after a relay round changed local files.
    func reloadAfterRelay() {
        reloadFromDisk()
    }

    // MARK: - Derived helpers for the UI

    /// The number the ring shows: live depth if a measurement is recent, else
    /// readiness. Nil means "nothing measured yet" and the UI must say so
    /// rather than drawing an empty ring that looks like a zero.
    var ringScore: Int? {
        today?.scores.liveFocus ?? today?.scores.readiness
    }

    var ringIsLive: Bool {
        today?.scores.liveFocus != nil
    }

    var ringLabel: String {
        if let live = today?.scores.liveFocus {
            return VitalsScoring.focusDepthLabel(live)
        }
        return VitalsScoring.readinessLabel(today?.scores.readiness)
    }

    /// Only the iPhone can ask for Health access, so the Mac never offers it —
    /// a permission button that cannot work is worse than none.
    var needsPermissionPrompt: Bool {
        #if os(iOS)
        return needsPermission
        #else
        return false
        #endif
    }

    /// The next hour the user reliably focuses in, if the profile knows one.
    func nextFocusWindow(after date: Date = .now, calendar: Calendar = .current) -> FocusWindow? {
        ChronotypeProfile.nextWindow(after: date, windows: focusWindows, calendar: calendar)
    }

    var focusNarrative: String {
        ChronotypeProfile.narrative(focusWindows)
    }

    /// The measured answer to the chronotype question onboarding already asked.
    var focusBucket: ChronotypeProfile.FocusBucket? {
        ChronotypeProfile.dominantBucket(focusWindows)
    }

    /// The block that rides the chat system prompt so ARCA answers condition
    /// questions from measurements instead of vibes.
    func chatContextBlock(now: Date = .now) -> String {
        VitalsPrompt.chatBlock(today: today, windows: focusWindows, now: now)
    }

    // MARK: - Apple Health link state (for the Connectors screen)

    /// How the Apple Health link looks to the user right now. Modelled as a
    /// single enum because the Connectors row has to say something true on both
    /// platforms, and on the Mac the honest answer is never "connected" — it's
    /// "your iPhone is connected and it sends the results here".
    enum HealthLink: Equatable {
        /// This device can't read Apple Health at all (every Mac).
        case unavailableHere
        case notAsked
        /// Permission asked for, but nothing has come through yet.
        case askedNoData
        case measuring(latestAt: Date)
        /// Mac: measurements arriving from the phone through the relay.
        case relayed(from: String, latestAt: Date)
        /// Mac: nothing has ever arrived.
        case awaitingPhone
    }

    /// The most recent day that actually carries measurements, and when it landed.
    private var latestMeasuredDay: DailyVitals? {
        history.last { !$0.metrics.isEmpty }
    }

    var healthLink: HealthLink {
        #if os(iOS)
        guard HealthVitals.isAvailable else { return .unavailableHere }
        guard !needsPermission else { return .notAsked }
        guard let day = latestMeasuredDay else { return .askedNoData }
        return .measuring(latestAt: day.updatedAt)
        #else
        guard let day = latestMeasuredDay else { return .awaitingPhone }
        return .relayed(from: day.device, latestAt: day.updatedAt)
        #endif
    }

    /// Short summary of what Apple Health is actually supplying, or nil when
    /// nothing is. Never invents a list of types it isn't really reading.
    var healthDataSummary: String? {
        guard let metrics = latestMeasuredDay?.metrics else { return nil }
        var parts: [String] = []
        if metrics.sleep != nil { parts.append(L("수면", "Sleep")) }
        if !metrics.hrv.isEmpty { parts.append("HRV") }
        if metrics.restingHeartRate != nil { parts.append(L("안정심박", "Resting HR")) }
        if metrics.activeEnergyKcal != nil || metrics.steps != nil {
            parts.append(L("활동", "Activity"))
        }
        if metrics.dietaryEnergyKcal != nil { parts.append(L("식사", "Meals")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
