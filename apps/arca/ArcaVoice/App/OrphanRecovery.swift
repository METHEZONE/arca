import Foundation
import SwiftData
import AVFoundation
import ArcaVoiceKit

/// Puts recordings the app lost track of back into the processing queue.
///
/// Two ways a recording used to become permanently invisible:
///
/// 1. Killed before the row existed at all (the row was only written in
///    `stop()`), leaving an `.m4a` under the sessions directory that nothing in
///    the app referenced. No screen could show it and no sweep looked for it.
/// 2. Killed while the row said `.recording`. Nothing is recording after a
///    relaunch, but no code path ever moved that state on, and only `.processing`
///    and errored sessions were retried.
///
/// Both are now adopted into `.processing`, which
/// `SessionRecovery.needsFinalPass` matches, so the existing final-pass retry
/// finishes them from the audio still on disk.
@MainActor
enum OrphanRecovery {
    struct Report: Equatable {
        /// Directories on disk that had no row at all.
        var adopted = 0
        /// Rows stuck in `.recording` from a killed session.
        var revived = 0

        var isEmpty: Bool { adopted == 0 && revived == 0 }
    }

    /// The smallest file worth recovering. An AAC container with nothing but a
    /// header is a recording that never captured a sample — the same floor
    /// `ProcessingPipeline` uses per channel.
    private static let minimumUsefulBytes = 4096

    @discardableResult
    static func run(context: ModelContext, activeDirectoryName: String?) -> Report {
        var report = Report()
        /// Tracks writes that don't show up in the report (a stranded row with no
        /// audio at all), which still have to be saved or they repeat every launch.
        var changed = false
        let sessions = (try? context.fetch(FetchDescriptor<RecordingSession>())) ?? []

        for record in sessions where SessionRecovery.isStrandedRecording(
            state: record.state,
            directoryName: record.directoryName,
            activeDirectoryName: activeDirectoryName
        ) {
            let directory = SessionPaths.directory(for: record.directoryName)
            let files = audioFiles(in: directory)
            guard !files.isEmpty else {
                // Killed before any audio landed. Nothing to transcribe, and
                // leaving it in `.recording` would show a live-looking row
                // forever.
                record.state = .failed
                record.processingError = "이 녹음은 저장되기 전에 앱이 종료되어 오디오가 남지 않았습니다."
                record.touch()
                changed = true
                continue
            }
            attachAssets(files, to: record)
            record.state = .processing
            record.processingError = nil
            record.touch()
            report.revived += 1
            changed = true
            DebugTrace.log("orphan recovery: revived stranded recording \(record.directoryName)")
        }

        let orphans = SessionRecovery.orphanDirectories(
            onDisk: sessionDirectoriesOnDisk(),
            known: sessions.map(\.directoryName))
        for name in orphans where name != activeDirectoryName {
            let files = audioFiles(in: SessionPaths.directory(for: name))
            guard !files.isEmpty else { continue }
            let created = createdAt(of: SessionPaths.directory(for: name))
            let record = RecordingSession(
                title: recoveredTitle(created: created),
                source: files.contains(where: { $0.channel == .systemAudio }) ? .macMeeting : .voiceMemo,
                directoryName: name,
                createdAt: created)
            attachAssets(files, to: record)
            record.state = .processing
            context.insert(record)
            report.adopted += 1
            changed = true
            DebugTrace.log("orphan recovery: adopted orphaned audio directory \(name)")
        }

        if changed {
            do {
                try context.save()
            } catch {
                DebugTrace.log("orphan recovery: save failed — \(error)")
                return Report()
            }
        }
        return report
    }

    // MARK: - Disk

    private static func sessionDirectoriesOnDisk() -> [String] {
        let root = SessionPaths.sessionsRoot
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
    }

    private struct FoundAudio {
        let channel: CaptureChannel
        let url: URL
        let duration: TimeInterval
    }

    /// Channel files big enough to be worth transcribing. Filenames come from
    /// `ChannelWriter`, which names each file after its channel.
    private static func audioFiles(in directory: URL) -> [FoundAudio] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles])) ?? []
        return contents.compactMap { url in
            guard url.pathExtension.lowercased() == "m4a" else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size >= minimumUsefulBytes else { return nil }
            let channel = CaptureChannel(rawValue: url.deletingPathExtension().lastPathComponent) ?? .mixed
            return FoundAudio(channel: channel, url: url, duration: duration(of: url))
        }
        .sorted { $0.channel.rawValue < $1.channel.rawValue }
    }

    /// Read off the container. A force-killed recording can have a written mdat
    /// with no moov box, in which case this reports 0 — the pass still runs, and
    /// the transcriber reports the real reason if the file is unusable.
    private static func duration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private static func attachAssets(_ files: [FoundAudio], to record: RecordingSession) {
        record.audioAssets.removeAll()
        for file in files {
            record.audioAssets.append(AudioAsset(
                channel: file.channel,
                relativePath: "\(record.directoryName)/\(file.url.lastPathComponent)",
                duration: file.duration))
        }
        let longest = files.map(\.duration).max() ?? 0
        if longest > record.duration { record.duration = longest }
    }

    private static func createdAt(of directory: URL) -> Date {
        (try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
    }

    private static func recoveredTitle(created: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "'복구된 녹음' MMM d, HH:mm"
        return formatter.string(from: created)
    }
}
