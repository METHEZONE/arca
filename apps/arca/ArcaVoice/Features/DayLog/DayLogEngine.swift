#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import Observation
import SwiftData
import ArcaVoiceKit

@MainActor
@Observable
final class DayLogEngine {
    private(set) var isEnabled = false
    private(set) var snapshotsEnabled = true
    private(set) var intervalMin = 5
    private(set) var digestHour = 21
    private(set) var isLocked = false
    private(set) var screenCaptureNeedsPermission = false
    private(set) var isGenerating = false
    private(set) var statusMessage: String?
    private(set) var todaySummaries: [DayLogAppSummary] = []
    private(set) var todaySnapshots: [URL] = []

    @ObservationIgnored private weak var container: ModelContainer?
    @ObservationIgnored private var activityTimer: Timer?
    @ObservationIgnored private var snapshotTimer: Timer?
    @ObservationIgnored private var digestTimer: Timer?
    @ObservationIgnored private var appObserver: NSObjectProtocol?
    @ObservationIgnored private var lockObserver: NSObjectProtocol?
    @ObservationIgnored private var unlockObserver: NSObjectProtocol?
    @ObservationIgnored private var lastTimelineEntry: DayLogTimelineEntry?

    private let defaults = UserDefaults.standard

    var statusText: String {
        if screenCaptureNeedsPermission { return "화면 기록 권한 필요" }
        if isEnabled { return "기록 중" }
        return "꺼짐"
    }

    func configure(container: ModelContainer) {
        self.container = container
        refreshSettings()
        Task.detached { cleanupOldDayLogFolders() }
        reloadToday()
        applySettings()
        startDigestTimer()
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: "dayTrackerEnabled")
        applySettings()
    }

    func applySettings() {
        let wasEnabled = isEnabled
        refreshSettings()
        if isEnabled {
            startActivityTracking()
            rescheduleSnapshotTimer()
            recordCurrentApplication()
        } else if wasEnabled {
            stopActivityTracking()
        }
    }

    func reloadToday() {
        let dayDir = Self.dayDirectory(for: .now)
        Task.detached {
            let entries = readTimelineEntries(from: dayDir.appendingPathComponent("timeline.jsonl"))
            let summaries = DayLogTimeline.summaries(from: entries)
            let snapshots = snapshotFiles(in: dayDir)
            await MainActor.run {
                self.todaySummaries = summaries
                self.todaySnapshots = snapshots
                self.lastTimelineEntry = entries.last
            }
        }
    }

    func generateTodayDigest(context: ModelContext) async -> RecordingSession? {
        guard !isGenerating else { return nil }
        isGenerating = true
        statusMessage = nil
        defer { isGenerating = false }

        do {
            let timeline = await digestTimelineMarkdown(context: context)
            let snapshots = await sampledSnapshotData()
            guard let key = KeychainStore.get(.anthropic), !key.isEmpty else {
                statusMessage = "Anthropic API key가 없어 오늘 정리를 만들 수 없습니다."
                DebugTrace.log("daylog digest skipped: missing anthropic key")
                return nil
            }

            let model = defaults.string(forKey: "chatModel") ?? "claude-sonnet-5"
            let digest = try await DayDigestGenerator(apiKey: key, model: model)
                .generate(timelineMarkdown: timeline, snapshotJPEGs: snapshots)
            let session = RecordingSession(title: digestTitle(suffix: digest.titleSuffix),
                                           source: .dayLog,
                                           createdAt: .now)
            session.state = .ready
            session.duration = 0
            let note = SessionNote()
            note.summaryMarkdown = digest.fullMarkdown
            session.note = note
            context.insert(session)
            try context.save()
            autoExportDayDigest(session)
            statusMessage = "오늘 정리를 라이브러리에 저장했습니다."
            return session
        } catch {
            statusMessage = error.localizedDescription
            DebugTrace.log("daylog digest failed: \(error)")
            return nil
        }
    }

    private func refreshSettings() {
        isEnabled = defaults.object(forKey: "dayTrackerEnabled") as? Bool ?? false
        snapshotsEnabled = defaults.object(forKey: "dayTrackerSnapshots") as? Bool ?? true
        intervalMin = defaults.object(forKey: "dayTrackerIntervalMin") as? Int ?? 5
        digestHour = defaults.object(forKey: "dayTrackerDigestHour") as? Int ?? 21
    }

    private func startActivityTracking() {
        if appObserver == nil {
            appObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.recordCurrentApplication() }
            }
        }
        if lockObserver == nil {
            lockObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.isLocked = true }
            }
        }
        if unlockObserver == nil {
            unlockObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.isLocked = false
                    self?.recordCurrentApplication()
                }
            }
        }
        if activityTimer == nil {
            activityTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.recordCurrentApplication() }
            }
        }
    }

    private func stopActivityTracking() {
        if let appObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appObserver)
        }
        if let lockObserver {
            DistributedNotificationCenter.default().removeObserver(lockObserver)
        }
        if let unlockObserver {
            DistributedNotificationCenter.default().removeObserver(unlockObserver)
        }
        appObserver = nil
        lockObserver = nil
        unlockObserver = nil
        activityTimer?.invalidate()
        snapshotTimer?.invalidate()
        activityTimer = nil
        snapshotTimer = nil
    }

    private func rescheduleSnapshotTimer() {
        snapshotTimer?.invalidate()
        guard isEnabled, snapshotsEnabled else {
            snapshotTimer = nil
            return
        }
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(1, intervalMin) * 60),
                                             repeats: true) { [weak self] _ in
            Task { @MainActor in self?.captureSnapshotIfAllowed() }
        }
    }

    private func startDigestTimer() {
        digestTimer?.invalidate()
        digestTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runAutoDigestIfNeeded() }
        }
    }

    private func runAutoDigestIfNeeded() {
        guard let context = container?.mainContext else { return }
        let lastDay = defaults.string(forKey: "lastDigestDay")
        guard DayDigestGuard.shouldGenerateDigest(now: .now,
                                                  enabled: isEnabled,
                                                  digestHour: digestHour,
                                                  lastDigestDay: lastDay) else {
            return
        }
        Task { @MainActor in
            if await self.generateTodayDigest(context: context) != nil {
                self.defaults.set(DayDigestGuard.dayString(for: .now), forKey: "lastDigestDay")
            }
        }
    }

    private func recordCurrentApplication() {
        guard isEnabled, !isLocked, !Self.isUserIdle else { return }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let entry = DayLogTimelineEntry(
            timestamp: .now,
            bundleId: app.bundleIdentifier ?? app.localizedName ?? "unknown",
            appName: app.localizedName ?? "Unknown App"
        )
        let nextEntries = DayLogTimeline.appending(entry, to: lastTimelineEntry.map { [$0] } ?? [])
        guard nextEntries.last == entry, lastTimelineEntry?.bundleId != entry.bundleId else { return }
        lastTimelineEntry = entry
        let lineURL = Self.dayDirectory(for: entry.timestamp).appendingPathComponent("timeline.jsonl")
        Task.detached {
            appendTimelineEntry(entry, to: lineURL)
        }
        reloadToday()
    }

    private func captureSnapshotIfAllowed() {
        guard isEnabled, snapshotsEnabled, !isLocked, !Self.isUserIdle else { return }
        let dayDir = Self.dayDirectory(for: .now)
        guard Self.snapshotCount(in: dayDir) < 120 else { return }

        Task {
            let result = await Self.captureSnapshot(in: dayDir)
            switch result {
            case .saved:
                screenCaptureNeedsPermission = false
            case .permissionNeeded:
                screenCaptureNeedsPermission = true
                DebugTrace.log("daylog snapshot skipped: screen recording permission likely missing")
            case .failed(let message):
                DebugTrace.log("daylog snapshot failed: \(message)")
            }
            reloadToday()
        }
    }

    private func digestTimelineMarkdown(context: ModelContext) async -> String {
        let dayStart = Calendar.current.startOfDay(for: .now)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? .now
        let dayDir = Self.dayDirectory(for: .now)
        let entries = await Task.detached {
            readTimelineEntries(from: dayDir.appendingPathComponent("timeline.jsonl"))
        }.value
        let summaries = DayLogTimeline.summaries(from: entries).prefix(15)
        let story = DayLogTimeline.compressedStory(from: entries)
        let sessions = ((try? context.fetch(FetchDescriptor<RecordingSession>())) ?? [])
            .filter { $0.createdAt >= dayStart && $0.createdAt < dayEnd && $0.source != .dayLog }
            .map(\.title)
        let tasks = ((try? context.fetch(FetchDescriptor<TodoTask>())) ?? [])
            .filter { task in
                (task.createdAt >= dayStart && task.createdAt < dayEnd)
                || (task.state == .done && task.updatedAt >= dayStart && task.updatedAt < dayEnd)
            }
            .map(\.title)

        let appLines = summaries.map {
            "- \($0.appName): \($0.minutes)분"
        }.joined(separator: "\n")
        let sessionLines = sessions.isEmpty ? "- 없음" : sessions.map { "- \($0)" }.joined(separator: "\n")
        let taskLines = tasks.isEmpty ? "- 없음" : tasks.map { "- \($0)" }.joined(separator: "\n")
        return """
        # 오늘의 로컬 타임라인

        ## 앱별 사용 시간
        \(appLines.isEmpty ? "- 기록 없음" : appLines)

        ## 앱 전환 흐름
        \(story)

        ## 오늘의 회의/세션
        \(sessionLines)

        ## 오늘 생성/완료한 Todo
        \(taskLines)
        """
    }

    private func sampledSnapshotData() async -> [Data] {
        guard snapshotsEnabled else { return [] }
        let urls = DayLogSnapshotSampler.evenlySampled(todaySnapshots, limit: 10)
        return await Task.detached {
            urls.compactMap { try? Data(contentsOf: $0) }
        }.value
    }

    private func autoExportDayDigest(_ session: RecordingSession) {
        let enabled = defaults.object(forKey: "autoObsidianExport") as? Bool ?? true
        guard enabled,
              let path = AccountDefaults.string("obsidianVaultPath"),
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        do {
            let expanded = (path as NSString).expandingTildeInPath
            _ = try ObsidianExporter.exportSession(session, to: URL(fileURLWithPath: expanded))
        } catch {
            DebugTrace.log("daylog obsidian export failed: \(error.localizedDescription)")
        }
    }

    private func digestTitle(suffix: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M월 d일"
        let cleanSuffix = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        return "하루 정리 — \(formatter.string(from: .now)) (\(cleanSuffix.isEmpty ? "오늘의 흐름" : cleanSuffix))"
    }

    private static var isUserIdle: Bool {
        let eventTypes: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .mouseMoved, .scrollWheel]
        let seconds = eventTypes
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
        return seconds > 180
    }

    private static func dayDirectory(for date: Date) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("ArcaVoice", isDirectory: true)
            .appendingPathComponent("daylog", isDirectory: true)
            .appendingPathComponent(DayDigestGuard.dayString(for: date), isDirectory: true)
    }

    private static func snapshotCount(in directory: URL) -> Int {
        snapshotFiles(in: directory).count
    }

    private static func captureSnapshot(in directory: URL) async -> SnapshotResult {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("arca-daylog-\(UUID().uuidString).jpg")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let ok = await run("/usr/sbin/screencapture", ["-x", "-t", "jpg", tmp.path])
            guard ok,
                  FileManager.default.fileExists(atPath: tmp.path),
                  (try? tmp.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0 else {
                return .permissionNeeded
            }
            guard let (data, _) = ImageDownscaler.jpeg(from: tmp, maxDimension: 1280, quality: 0.5) else {
                return .failed("downscale failed")
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "HHmm"
            let finalURL = directory.appendingPathComponent("\(formatter.string(from: .now)).jpg")
            try data.write(to: finalURL, options: .atomic)
            return .saved(finalURL)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func run(_ path: String, _ args: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private enum SnapshotResult: Sendable {
        case saved(URL)
        case permissionNeeded
        case failed(String)
    }
}

private func appendTimelineEntry(_ entry: DayLogTimelineEntry, to url: URL) {
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entry)
        guard let json = String(data: data, encoding: .utf8),
              let line = "\(json)\n".data(using: .utf8) else {
            return
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    } catch {
        DebugTrace.log("daylog timeline write failed: \(error.localizedDescription)")
    }
}

private func readTimelineEntries(from url: URL) -> [DayLogTimelineEntry] {
    guard let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .utf8) else {
        return []
    }
    let decoder = JSONDecoder()
    return text.split(separator: "\n").compactMap { line in
        try? decoder.decode(DayLogTimelineEntry.self, from: Data(line.utf8))
    }
}

private func snapshotFiles(in directory: URL) -> [URL] {
    guard let urls = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: [.contentModificationDateKey],
                                                                  options: [.skipsHiddenFiles]) else {
        return []
    }
    return urls
        .filter { $0.pathExtension.lowercased() == "jpg" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

private func cleanupOldDayLogFolders(now: Date = .now) {
    let root = DayLogRoot.url
    guard let folders = try? FileManager.default.contentsOfDirectory(at: root,
                                                                     includingPropertiesForKeys: [.isDirectoryKey],
                                                                     options: [.skipsHiddenFiles]) else {
        return
    }
    let cutoff = now.addingTimeInterval(-14 * 24 * 60 * 60)
    for folder in folders {
        guard let values = try? folder.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true,
              let date = DayLogRoot.folderDate(folder.lastPathComponent),
              date < cutoff else {
            continue
        }
        try? FileManager.default.removeItem(at: folder)
    }
}

private enum DayLogRoot {
    static var url: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("ArcaVoice", isDirectory: true)
            .appendingPathComponent("daylog", isDirectory: true)
    }

    static func folderDate(_ name: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: name)
    }
}
#endif
