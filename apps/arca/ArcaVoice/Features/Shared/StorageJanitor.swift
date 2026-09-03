import Foundation
import SwiftData
import ArcaVoiceKit

/// Keeps ARCA's footprint honest. Recordings are the heavy part (a one-hour
/// meeting is tens of megabytes); their words — transcript, summary, decisions
/// — are tiny and are what people come back for. So after a retention period
/// the audio goes and the words stay, unless the user says keep everything.
/// Logs are truncated when they grow past a megabyte.
@MainActor
@Observable
final class StorageJanitor {
    static let shared = StorageJanitor()

    /// Days to keep audio for; 0 = forever.
    static let retentionKey = "audioRetentionDays"
    static let defaultRetentionDays = 30
    static let retentionChoices = [7, 30, 90, 0]

    struct Report: Equatable {
        var audioBytes: Int64 = 0
        var audioSessions = 0
        var dayLogBytes: Int64 = 0
        var logBytes: Int64 = 0
        var purgeableSessions = 0
        var purgeableBytes: Int64 = 0
    }

    private(set) var report = Report()
    private(set) var lastRun: Date?
    private(set) var isWorking = false

    var retentionDays: Int {
        get { UserDefaults.standard.object(forKey: Self.retentionKey) as? Int ?? Self.defaultRetentionDays }
        set { UserDefaults.standard.set(newValue, forKey: Self.retentionKey) }
    }

    private static var lastRunKey: String { AccountDefaults.key("storageJanitorLastRun") }

    /// Once a day, in the background of the first home screen.
    func runIfDue(context: ModelContext) {
        let last = UserDefaults.standard.object(forKey: Self.lastRunKey) as? Date
        if let last, Date.now.timeIntervalSince(last) < 20 * 3600 { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(15))
            _ = purge(context: context)
            rotateLogs()
            UserDefaults.standard.set(Date.now, forKey: Self.lastRunKey)
        }
    }

    /// Measures without touching anything.
    func measure(context: ModelContext) {
        var r = Report()
        let sessions = (try? context.fetch(FetchDescriptor<RecordingSession>())) ?? []
        let cutoff = retentionDays == 0 ? Date.distantPast : Date.now.addingTimeInterval(-Double(retentionDays) * 86_400)
        for session in sessions where !session.audioAssets.isEmpty {
            let bytes = session.audioAssets.reduce(Int64(0)) { $0 + Self.fileSize(SessionPaths.resolve(relativePath: $1.relativePath)) }
            guard bytes > 0 else { continue }
            r.audioBytes += bytes
            r.audioSessions += 1
            if Self.isPurgeable(session, cutoff: cutoff) {
                r.purgeableSessions += 1
                r.purgeableBytes += bytes
            }
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArcaVoice", isDirectory: true)
        r.dayLogBytes = Self.directorySize(support.appendingPathComponent("daylog", isDirectory: true))
        r.logBytes = Self.fileSize(support.appendingPathComponent("trace.log")) + Self.fileSize(support.appendingPathComponent("keychain-trace.log"))
        report = r
    }

    /// Deletes audio files (and their rows) for sessions past retention whose
    /// final transcript exists. Returns how many sessions were trimmed.
    @discardableResult
    func purge(context: ModelContext) -> Int {
        guard retentionDays > 0 else { measure(context: context); return 0 }
        isWorking = true
        defer { isWorking = false; lastRun = .now }
        let cutoff = Date.now.addingTimeInterval(-Double(retentionDays) * 86_400)
        let sessions = (try? context.fetch(FetchDescriptor<RecordingSession>())) ?? []
        var trimmed = 0
        for session in sessions where Self.isPurgeable(session, cutoff: cutoff) && !session.audioAssets.isEmpty {
            for asset in session.audioAssets {
                try? FileManager.default.removeItem(at: SessionPaths.resolve(relativePath: asset.relativePath))
                context.delete(asset)
            }
            session.audioAssets = []
            let dir = SessionPaths.directory(for: session.directoryName)
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
                try? FileManager.default.removeItem(at: dir)
            }
            trimmed += 1
        }
        if trimmed > 0 { try? context.save() }
        measure(context: context)
        return trimmed
    }

    /// Only recordings whose words are safely stored lose their audio.
    private static func isPurgeable(_ session: RecordingSession, cutoff: Date) -> Bool {
        guard session.createdAt < cutoff, session.state == .ready else { return false }
        let hasWords = session.segments.contains { $0.isFinal } || !(session.note?.summaryMarkdown ?? "").isEmpty
        return hasWords && !session.qualityPassPending
    }

    /// Trace logs grow without bound; keep the last ~200 KB of each.
    func rotateLogs() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArcaVoice", isDirectory: true)
        for name in ["trace.log", "keychain-trace.log"] {
            let url = support.appendingPathComponent(name)
            guard Self.fileSize(url) > 1_000_000, let data = try? Data(contentsOf: url) else { continue }
            let tail = data.suffix(200_000)
            try? tail.write(to: url, options: .atomic)
        }
    }

    static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
