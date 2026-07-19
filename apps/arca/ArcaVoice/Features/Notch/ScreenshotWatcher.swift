#if os(macOS)
import Foundation

/// Spotlight-based watcher for new screenshots (kMDItemIsScreenCapture).
/// Fires only for captures taken after start() — the initial gather is ignored.
@MainActor
final class ScreenshotWatcher {
    private let query = NSMetadataQuery()
    private let onCapture: @MainActor (URL) -> Void
    private var startedAt = Date()
    private var observers: [NSObjectProtocol] = []
    private var seenPaths = Set<String>()

    init(onCapture: @escaping @MainActor (URL) -> Void) {
        self.onCapture = onCapture
    }

    func start() {
        startedAt = Date()
        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1")
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.notificationBatchingInterval = 1.0

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Baseline: everything that already exists is "seen".
                for item in self.query.results.compactMap({ $0 as? NSMetadataItem }) {
                    if let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                        self.seenPaths.insert(path)
                    }
                }
                self.query.enableUpdates()
            }
        })
        observers.append(center.addObserver(
            forName: .NSMetadataQueryDidUpdate, object: query, queue: .main
        ) { notification in
            // Pull the added items out before hopping isolation — Notification
            // itself is not Sendable.
            let added = (notification.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem]) ?? []
            let paths = added.compactMap { $0.value(forAttribute: NSMetadataItemPathKey) as? String }
            MainActor.assumeIsolated {
                ScreenshotWatcher.active?.handleAdded(paths: paths)
            }
        })
        Self.active = self
        query.start()
    }

    /// The single live watcher (one per app); lets the notification closure
    /// reach main-actor state without capturing non-Sendable self.
    private static weak var active: ScreenshotWatcher?

    private func handleAdded(paths: [String]) {
        // The companion runs for weeks; don't hoard every path ever seen.
        if seenPaths.count > 2000 { seenPaths.removeAll() }
        for path in paths {
            guard !seenPaths.contains(path) else { continue }
            seenPaths.insert(path)
            let url = URL(fileURLWithPath: path)
            // Give the screencapture process a beat to finish writing.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard FileManager.default.isReadableFile(atPath: path) else { return }
                self?.onCapture(url)
            }
        }
    }
}
#endif
