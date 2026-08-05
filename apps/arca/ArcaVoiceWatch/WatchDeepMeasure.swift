import Foundation
import HealthKit
import os

/// The on-demand focus measurement.
///
/// This is the *only* thing in ARCA that turns a sensor on, and it runs solely
/// because the user pressed a button. The everyday picture of their body comes
/// from data the Watch already wrote on its own schedule, which the iPhone reads
/// out of Apple Health for free. That split is the whole battery story: a
/// continuous session would give a prettier graph and cost real hours of wrist
/// life, so it only runs for the couple of minutes that were asked for.
@MainActor
@Observable
final class WatchVitalsStatus {
    static let shared = WatchVitalsStatus()

    private(set) var isMeasuring = false
    private(set) var secondsRemaining = 0
    private(set) var totalSeconds = 0
    private(set) var currentHR: Double?
    private(set) var lastDepthLabel: String?
    private(set) var errorMessage: String?

    // The body read, as computed on the iPhone. The wrist can't score it itself —
    // the baselines live in Apple Health on the phone — so it displays, never derives.
    private(set) var ringScore: Int?
    private(set) var ringIsLive = false
    private(set) var ringLabel = ""
    private(set) var nextWindow: String?
    private(set) var sleepMinutes: Int?

    func receive(ringScore: Int?, isLive: Bool, label: String,
                 nextWindow: String?, sleepMinutes: Int?) {
        self.ringScore = ringScore
        self.ringIsLive = isLive
        self.ringLabel = label
        self.nextWindow = nextWindow
        self.sleepMinutes = sleepMinutes
    }

    var progress: Double {
        guard totalSeconds > 0 else { return 0 }
        return Double(totalSeconds - secondsRemaining) / Double(totalSeconds)
    }

    func begin(seconds: Int) {
        isMeasuring = true
        totalSeconds = seconds
        secondsRemaining = seconds
        currentHR = nil
        lastDepthLabel = nil
        errorMessage = nil
    }

    func tick() {
        secondsRemaining = max(0, secondsRemaining - 1)
    }

    func update(hr: Double) { currentHR = hr }

    func finish(sentToPhone: Bool) {
        isMeasuring = false
        secondsRemaining = 0
        lastDepthLabel = sentToPhone
            ? L("아이폰으로 보냈어요", "Sent to your iPhone")
            : L("저장했지만 아이폰에 아직 못 보냈어요", "Saved, but not sent to your iPhone yet")
    }

    func fail(_ message: String) {
        isMeasuring = false
        secondsRemaining = 0
        errorMessage = message
    }
}

/// Runs a `mindAndBody` workout session for the requested duration, streams heart
/// rate out of it, and reports the raw numbers to the iPhone.
///
/// Deliberately *not* the place where focus depth is decided: scoring needs the
/// user's own resting-heart-rate baseline, which lives in Apple Health on the
/// phone. The wrist reports what it saw; the phone decides what it means.
final class WatchDeepMeasure: NSObject, @unchecked Sendable {
    static let shared = WatchDeepMeasure()

    private let store = HKHealthStore()
    private let state = OSAllocatedUnfairLock(initialState: Run())

    private struct Run {
        var session: HKWorkoutSession?
        var builder: HKLiveWorkoutBuilder?
        var readings: [Double] = []
        var startedAt: Date?
        var requestedSeconds = 0
        var isRunning = false
        var timer: Task<Void, Never>?
    }

    private static var readTypes: Set<HKObjectType> {
        [HKQuantityType(.heartRate), HKQuantityType(.heartRateVariabilitySDNN)]
    }

    private static var shareTypes: Set<HKSampleType> {
        [HKCategoryType(.mindfulSession)]
    }

    /// Starts a measurement. Safe to call twice — a second call while one is
    /// already running is ignored rather than tearing the first one down.
    func start(seconds: Int) {
        guard HKHealthStore.isHealthDataAvailable() else {
            Task { @MainActor in
                WatchVitalsStatus.shared.fail(L("이 워치에서 건강 데이터를 쓸 수 없어요.",
                                                "Health data isn't available on this watch."))
            }
            return
        }
        let alreadyRunning = state.withLock { run -> Bool in
            if run.isRunning { return true }
            run.isRunning = true
            run.readings = []
            run.startedAt = .now
            run.requestedSeconds = seconds
            return false
        }
        guard !alreadyRunning else { return }

        Task { @MainActor in WatchVitalsStatus.shared.begin(seconds: seconds) }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.store.requestAuthorization(toShare: Self.shareTypes, read: Self.readTypes)
                try self.beginSession()
                self.startCountdown(seconds: seconds)
            } catch {
                self.state.withLock { $0.isRunning = false }
                let message = error.localizedDescription
                Task { @MainActor in WatchVitalsStatus.shared.fail(message) }
            }
        }
    }

    private func beginSession() throws {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .mindAndBody
        configuration.locationType = .indoor

        let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
        let builder = session.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: store,
                                                     workoutConfiguration: configuration)
        session.delegate = self
        builder.delegate = self

        let start = Date()
        session.startActivity(with: start)
        builder.beginCollection(withStart: start) { _, _ in }

        state.withLock { run in
            run.session = session
            run.builder = builder
            run.startedAt = start
        }
    }

    private func startCountdown(seconds: Int) {
        let timer = Task { [weak self] in
            for _ in 0..<seconds {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                await MainActor.run { WatchVitalsStatus.shared.tick() }
            }
            guard !Task.isCancelled else { return }
            self?.finish()
        }
        state.withLock { $0.timer = timer }
    }

    /// Ends the measurement early; the readings collected so far still count.
    func stop() {
        finish()
    }

    private func finish() {
        let run = state.withLock { run -> Run in
            let snapshot = run
            run.timer?.cancel()
            run.timer = nil
            run.isRunning = false
            run.session = nil
            run.builder = nil
            return snapshot
        }
        guard let session = run.session, let startedAt = run.startedAt else { return }

        let end = Date()
        session.end()
        // The workout itself is discarded rather than saved: a two-minute focus
        // check is not a workout, and logging one would put a phantom entry in
        // the user's Activity rings. The time is credited as mindful minutes,
        // which is what it actually was.
        run.builder?.endCollection(withEnd: end) { [weak self] _, _ in
            run.builder?.discardWorkout()
            self?.report(readings: run.readings, startedAt: startedAt, end: end)
        }
    }

    private func report(readings: [Double], startedAt: Date, end: Date) {
        let seconds = Int(end.timeIntervalSince(startedAt))
        guard readings.count >= 3, let minHR = readings.min(), let maxHR = readings.max() else {
            Task { @MainActor in
                WatchVitalsStatus.shared.fail(
                    L("심박을 충분히 모으지 못했어요. 30초 이상 손목에 붙여 두고 다시 해주세요.",
                      "Couldn't gather enough heartbeats. Keep it snug on your wrist for at least 30 seconds and try again."))
            }
            return
        }
        let meanHR = readings.reduce(0, +) / Double(readings.count)

        Task { [weak self] in
            guard let self else { return }
            try? await self.store.save(HKCategorySample(
                type: HKCategoryType(.mindfulSession),
                value: HKCategoryValue.notApplicable.rawValue,
                start: startedAt, end: end))

            let sdnn = await self.hrvSDNN(from: startedAt, to: end)
            let sent = WatchSync.shared.send(
                deepMeasureStartedAt: startedAt, seconds: seconds,
                meanHR: meanHR, minHR: minHR, maxHR: maxHR,
                hrvSDNN: sdnn,
                beatIntervalSD: Self.beatIntervalSD(fromHeartRates: readings))
            await MainActor.run { WatchVitalsStatus.shared.finish(sentToPhone: sent) }
        }
    }

    /// A real SDNN sample, if watchOS happened to write one inside the window.
    /// Often it doesn't over a couple of minutes, which is why the estimate
    /// below exists as a fallback rather than the other way round.
    private func hrvSDNN(from start: Date, to end: Date) async -> Double? {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(.heartRateVariabilitySDNN),
                                         predicate: predicate)],
            sortDescriptors: [SortDescriptor(\HKQuantitySample.startDate, order: .reverse)],
            limit: 1)
        guard let sample = try? await descriptor.result(for: store).first else { return nil }
        return sample.quantity.doubleValue(for: .secondUnit(with: .milli))
    }

    /// Standard deviation of beat-to-beat intervals implied by the heart-rate
    /// stream, in milliseconds.
    ///
    /// This is an **estimate, not SDNN**. watchOS doesn't hand third-party apps
    /// raw RR intervals outside an ECG, so this is derived from averaged
    /// heart-rate samples: it captures short-term rate drift rather than true
    /// beat-to-beat variability, and reads lower than a real SDNN would. Every
    /// surface that shows it labels it as an estimate for exactly that reason.
    static func beatIntervalSD(fromHeartRates readings: [Double]) -> Double? {
        let intervals = readings.filter { $0 > 20 }.map { 60_000 / $0 }
        guard intervals.count >= 3 else { return nil }
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        let variance = intervals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(intervals.count - 1)
        return variance.squareRoot()
    }
}

// MARK: - HealthKit delegates

extension WatchDeepMeasure: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession,
                        didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState, date: Date) {}

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        state.withLock { run in
            run.timer?.cancel()
            run.timer = nil
            run.isRunning = false
        }
        let message = error.localizedDescription
        Task { @MainActor in WatchVitalsStatus.shared.fail(message) }
    }
}

extension WatchDeepMeasure: HKLiveWorkoutBuilderDelegate {
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                        didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let heartRateType = HKQuantityType(.heartRate)
        guard collectedTypes.contains(heartRateType),
              let statistics = workoutBuilder.statistics(for: heartRateType),
              let latest = statistics.mostRecentQuantity() else { return }
        let bpm = latest.doubleValue(for: .count().unitDivided(by: .minute()))
        guard bpm > 20 else { return }
        state.withLock { $0.readings.append(bpm) }
        Task { @MainActor in WatchVitalsStatus.shared.update(hr: bpm) }
    }
}
