import Foundation
import Network
import SwiftData
import ArcaVoiceKit

/// Keeps re-offering un-transcribed recordings to the cloud pass until it lands.
///
/// Live transcription runs on-device, so a recording made on a plane is already
/// complete and readable the moment it stops — only the diarized pass and the
/// notes need a network. That makes being offline a *delay*, not a failure, and
/// the delay has to end by itself: waiting for the next cold launch leaves a
/// day of meetings un-summarized for as long as the user never quits ARCA.
///
/// Three triggers, because there are three reasons a pass is outstanding:
/// connectivity came back, an API key was just added, or the app came back to
/// the foreground after a long sleep.
@MainActor
final class PassRetryScheduler {
    static let shared = PassRetryScheduler()

    private var container: ModelContainer?
    private var ownerName: () -> String = { "Me" }
    private var languageHints: () -> [String] = { [] }
    private var monitor: NWPathMonitor?
    /// Starts pessimistic so the first satisfied path counts as "came back" and
    /// sweeps whatever the last offline stretch left behind.
    private var isOnline = false
    private var lastSweep: Date = .distantPast

    /// Two consecutive sweeps can't be closer than this. A flapping Wi-Fi link
    /// fires the path handler repeatedly, and each sweep can start an upload.
    private let minimumInterval: TimeInterval = 30

    func start(container: ModelContainer,
               ownerName: @escaping () -> String,
               languageHints: @escaping () -> [String]) {
        guard monitor == nil else { return }
        self.container = container
        self.ownerName = ownerName
        self.languageHints = languageHints

        // Launch sweep also reclaims sessions stranded in `.processing` by a
        // previous run that was killed mid-upload.
        sweep(resetStuckPasses: true, force: true)

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let cameBack = satisfied && !self.isOnline
                self.isOnline = satisfied
                guard cameBack else { return }
                self.sweep()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.thezone.arca.passretry"))
        self.monitor = monitor
    }

    /// Called after Settings saves a key: the recordings that failed for "no
    /// key" are now fixable, and making the user wait for a relaunch to find
    /// that out is the kind of thing that makes a key feel like it didn't work.
    func keysChanged() {
        sweep(force: true)
    }

    /// Foreground/scene-activation hook, for a phone that stayed open for days.
    func appBecameActive() {
        sweep()
    }

    private func sweep(resetStuckPasses: Bool = false, force: Bool = false) {
        guard let context = container?.mainContext else { return }
        if !force, Date.now.timeIntervalSince(lastSweep) < minimumInterval { return }
        lastSweep = .now
        FinalPassRunner.retryPending(
            context: context,
            ownerName: ownerName(),
            languageHints: languageHints(),
            resetStuckPasses: resetStuckPasses)
    }
}
