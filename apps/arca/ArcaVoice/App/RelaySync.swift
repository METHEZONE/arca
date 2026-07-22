import CryptoKit
import Foundation
import SwiftData
import ArcaVoiceKit

/// Keeps every device's task list converged through the arca-brain repo, and
/// turns the Mac into the household agent: tasks tossed on the iPhone relay
/// here and the Mac runs them (Claude for research/drafts, Codex for actions),
/// pushing results back for the phone to see.
@MainActor
@Observable
final class RelaySync {
    static let shared = RelaySync()

    private(set) var lastSyncAt: Date?
    private(set) var lastError: String?

    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var syncing = false

    func configure(container: ModelContainer) {
        self.container = container
        dedupeUIDs()
        #if os(macOS)
        // The Mac is the always-on side: poll so phone-created tasks get
        // picked up and run without the app being touched.
        loopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                // Ambient ops, todo triage, and the Obsidian pull all ride the
                // same heartbeat (each throttles itself internally).
                if let context = self?.container?.mainContext {
                    await AmbientOps.shared.harvest(context: context)
                    TodoTriage.sweepIfDue(context: context)
                    await ObsidianAutoImport.runIfDue(context: context)
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
        #endif
    }

    /// Push soon (debounced) — call after local mutations.
    func scheduleSync(after seconds: Double = 3) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    /// One full pull → merge → push cycle (with one conflict retry).
    func syncNow() async {
        guard !syncing, let context = container?.mainContext,
              let relay = GitHubRelay() else { return }
        syncing = true
        defer { syncing = false }
        do {
            for attempt in 0..<2 {
                let remote = try await relay.pull([TaskWire].self, path: "tasks.json")
                let merged = merge(remote.value ?? [], into: context)
                do {
                    try await relay.push(merged, path: "tasks.json", sha: remote.sha,
                                         message: "sync from \(Self.deviceName)")
                    break
                } catch GitHubRelay.RelayError.conflict where attempt == 0 {
                    continue
                }
            }
            await syncSessions(relay: relay, context: context)
            lastSyncAt = .now
            lastError = nil
            #if os(macOS)
            runRelayedTasks(context: context)
            #endif
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Sessions (transcripts + notes; audio stays local)

    /// One shared library across devices: push finished local sessions the
    /// other side hasn't seen, pull remote ones we don't have (or that got
    /// newer notes). Change detection is content-hash for pushes and blob-sha
    /// for pulls, so steady state costs one directory listing.
    private func syncSessions(relay: GitHubRelay, context: ModelContext) async {
        let defaults = UserDefaults.standard
        var pulledShas = (defaults.dictionary(forKey: "relaySessionShas") as? [String: String]) ?? [:]
        var pushedHashes = (defaults.dictionary(forKey: "relaySessionPushedHashes") as? [String: String]) ?? [:]

        guard let listing = try? await relay.listDirectory(path: "sessions") else { return }
        var remoteShaByName = [String: String]()
        for entry in listing { remoteShaByName[entry.name] = entry.sha }

        let locals = (try? context.fetch(FetchDescriptor<RecordingSession>())) ?? []
        var localByUID = Dictionary(uniqueKeysWithValues: locals.map { ($0.directoryName, $0) })

        // Pull: new/changed remote sessions.
        for entry in listing where pulledShas[entry.name] != entry.sha {
            guard let remote = try? await relay.pull(SessionWire.self, path: "sessions/\(entry.name)"),
                  let wire = remote.value else { continue }
            if let local = localByUID[wire.uid] {
                if wire.updatedAt > local.updatedAt {
                    wire.apply(to: local, context: context)
                }
            } else {
                let session = RecordingSession(
                    title: wire.title,
                    source: SessionSource(rawValue: wire.sourceRaw) ?? .voiceMemo,
                    directoryName: wire.uid)
                wire.apply(to: session, context: context)
                context.insert(session)
                localByUID[wire.uid] = session
            }
            pulledShas[entry.name] = entry.sha
        }
        try? context.save()

        // Push: finished sessions whose content changed since the last push.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        for session in localByUID.values
        where session.state == .ready && (!session.segments.isEmpty || session.note != nil) {
            let wire = SessionWire(session)
            guard let blob = try? encoder.encode(wire) else { continue }
            let digest = SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined()
            let filename = "\(session.directoryName).json"
            guard pushedHashes[filename] != digest else { continue }
            do {
                let newSha = try await relay.push(wire, path: "sessions/\(filename)",
                                                  sha: remoteShaByName[filename],
                                                  message: "session sync from \(Self.deviceName)")
                pushedHashes[filename] = digest
                pulledShas[filename] = newSha
            } catch {
                continue
            }
        }

        defaults.set(pulledShas, forKey: "relaySessionShas")
        defaults.set(pushedHashes, forKey: "relaySessionPushedHashes")
    }

    /// Applies remote wires onto local records (per-uid: keep whichever side
    /// is further along; ties go to the newest update) and returns the union.
    private func merge(_ wires: [TaskWire], into context: ModelContext) -> [TaskWire] {
        let locals = (try? context.fetch(FetchDescriptor<TodoTask>())) ?? []
        var byUID = Dictionary(uniqueKeysWithValues: locals.map { ($0.uid, $0) })
        for wire in wires {
            if let local = byUID[wire.uid] {
                let localRank = TodoTask.rank(of: local.state)
                let wireRank = TodoTask.rank(of: TaskState(rawValue: wire.stateRaw) ?? .open)
                let wireWins = wireRank > localRank
                    || (wireRank == localRank && wire.updatedAt > local.updatedAt)
                if wireWins { wire.apply(to: local) }
            } else {
                let task = TodoTask(title: wire.title)
                wire.apply(to: task)
                task.uid = wire.uid
                context.insert(task)
                byUID[wire.uid] = task
            }
        }
        // Tombstones stay a week (long enough for every device to see the
        // deletion), then leave both the store and the relay file for good.
        let tombstoneCutoff = Date.now.addingTimeInterval(-7 * 86_400)
        for (uid, task) in byUID where task.state == .trashed && task.updatedAt < tombstoneCutoff {
            context.delete(task)
            byUID[uid] = nil
        }
        try? context.save()
        return byUID.values.map(TaskWire.init)
    }

    #if os(macOS)
    /// The Mac agent: classify unjudged relay arrivals, then run anything the
    /// user tossed on another device (state == .tossed) or that the autonomy
    /// level lets ARCA take end-to-end without being asked.
    private func runRelayedTasks(context: ModelContext) {
        let tasks = (try? context.fetch(FetchDescriptor<TodoTask>())) ?? []
        for task in tasks {
            switch task.state {
            case .open where task.autonomyRationale.isEmpty && task.sourceRaw != "mac":
                Task { @MainActor in
                    await TaskEngine.shared.classify(task)
                    task.touch()
                    try? context.save()
                    // Full delegation: if the trust level covers it, the Mac
                    // just does it — that's what "arca it" means.
                    if task.isTossable() {
                        TaskEngine.shared.toss(task)
                    }
                    self.scheduleSync()
                }
            case .tossed:
                // Tossed elsewhere (e.g. iPhone) — the Mac actually runs it.
                TaskEngine.shared.toss(task)
                scheduleSync(after: 10)
            default:
                break
            }
        }
    }
    #endif

    /// A one-time safety net: rows migrated before `uid` existed can share a
    /// generated value — regenerate duplicates so relay identity is unique.
    private func dedupeUIDs() {
        guard let context = container?.mainContext,
              let tasks = try? context.fetch(FetchDescriptor<TodoTask>()) else { return }
        var seen = Set<UUID>()
        for task in tasks {
            if seen.contains(task.uid) { task.uid = UUID() }
            seen.insert(task.uid)
        }
        try? context.save()
    }

    private static var deviceName: String {
        #if os(macOS)
        return "mac"
        #else
        return "iphone"
        #endif
    }
}
