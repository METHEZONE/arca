#if os(iOS)
import Foundation
import SwiftData
import WatchConnectivity
import ArcaVoiceKit

/// Receives Watch recordings and runs them through the same pipeline as
/// phone recordings (no live pass — straight to the quality pass).
final class PhoneWatchSync: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = PhoneWatchSync()

    private var container: ModelContainer?

    func configure(container: ModelContainer) {
        self.container = container
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The incoming file is deleted when this method returns — move it now.
        let directoryName = UUID().uuidString
        let directory = SessionPaths.directory(for: directoryName)
        let destination = directory.appendingPathComponent("microphone.m4a")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file.fileURL, to: destination)
        } catch {
            return
        }
        let duration = (file.metadata?["duration"] as? Double) ?? 0
        let startedAt = (file.metadata?["createdAt"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? .now

        Task { @MainActor in
            guard let container = self.container else { return }
            let context = container.mainContext

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.dateFormat = "MMM d, HH:mm"
            let record = RecordingSession(
                title: "⌚️ \(formatter.string(from: startedAt)) recording",
                source: .watchMemo,
                directoryName: directoryName,
                createdAt: startedAt)
            record.duration = duration
            record.state = .processing
            record.audioAssets.append(AudioAsset(
                channel: .microphone,
                relativePath: "\(directoryName)/microphone.m4a",
                duration: duration))
            record.note = SessionNote()
            context.insert(record)
            try? context.save()

            FinalPassRunner.run(
                record: record,
                files: [.microphone: destination],
                userNotes: nil,
                ownerName: UserDefaults.standard.string(forKey: "ownerName") ?? "Me",
                languageHints: TranscriptionPrefs.languageHints)
        }
    }
}
#endif
