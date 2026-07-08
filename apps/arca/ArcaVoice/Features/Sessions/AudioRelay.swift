import Foundation
import SwiftData
import ArcaVoiceKit

/// On-demand audio transfer through the arca-brain repo. Audio normally stays
/// on the device that recorded it; when the user asks, the owning device
/// uploads `audio/<uid>/<channel>.m4a` and any other device can download it
/// and re-listen. Manual and per-session — never automatic bulk sync.
@MainActor
@Observable
final class AudioRelay {
    static let shared = AudioRelay()

    enum Activity: Equatable {
        case idle
        case working(String)
        case done(String)
        case failed(String)
    }

    /// Per-session activity, keyed by `RecordingSession.directoryName`.
    private(set) var activity: [String: Activity] = [:]

    /// GitHub's contents API rejects files over 100MB; leave headroom.
    private static let maxBytes = 90 * 1024 * 1024

    func state(for uid: String) -> Activity { activity[uid] ?? .idle }

    /// Push every locally-present audio file of this session to the brain.
    func upload(session: RecordingSession) async {
        let uid = session.directoryName
        guard let relay = GitHubRelay() else {
            activity[uid] = .failed("Relay isn't configured (Settings → Sync)")
            return
        }
        let assets = session.audioAssets.filter {
            FileManager.default.fileExists(atPath: SessionPaths.resolve(relativePath: $0.relativePath).path)
        }
        guard !assets.isEmpty else {
            activity[uid] = .failed("No local audio on this device")
            return
        }

        for (index, asset) in assets.enumerated() {
            let url = SessionPaths.resolve(relativePath: asset.relativePath)
            activity[uid] = .working("Uploading \(index + 1)/\(assets.count)…")
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= Self.maxBytes else {
                    activity[uid] = .failed("\(url.lastPathComponent) is over the 90MB relay limit")
                    return
                }
                let path = "audio/\(uid)/\(url.lastPathComponent)"
                let existing = try? await relay.listDirectory(path: "audio/\(uid)")
                let sha = existing?.first(where: { $0.name == url.lastPathComponent })?.sha
                try await relay.pushRaw(data, path: path, sha: sha,
                                        message: "audio for \(session.title)")
            } catch {
                activity[uid] = .failed(error.localizedDescription)
                return
            }
        }
        activity[uid] = .done("Audio is in the brain — other devices can download it")
    }

    /// Fetch this session's audio from the brain onto this device.
    func download(session: RecordingSession) async {
        let uid = session.directoryName
        guard let relay = GitHubRelay() else {
            activity[uid] = .failed("Relay isn't configured (Settings → Sync)")
            return
        }
        activity[uid] = .working("Checking the brain…")
        do {
            let listing = try await relay.listDirectory(path: "audio/\(uid)")
            guard !listing.isEmpty else {
                activity[uid] = .failed("No audio in the brain yet — upload it from the device that recorded this")
                return
            }
            let directory = SessionPaths.directory(for: uid)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            for (index, entry) in listing.enumerated() {
                activity[uid] = .working("Downloading \(index + 1)/\(listing.count)…")
                guard let data = try await relay.pullRaw(path: "audio/\(uid)/\(entry.name)") else { continue }
                try data.write(to: directory.appendingPathComponent(entry.name))

                let relativePath = "\(uid)/\(entry.name)"
                if !session.audioAssets.contains(where: { $0.relativePath == relativePath }) {
                    let channel: CaptureChannel =
                        entry.name.lowercased().contains("system") ? .systemAudio : .microphone
                    session.audioAssets.append(AudioAsset(
                        channel: channel, relativePath: relativePath, duration: session.duration))
                }
            }
            try? session.modelContext?.save()
            activity[uid] = .done("Audio downloaded — tap play")
        } catch {
            activity[uid] = .failed(error.localizedDescription)
        }
    }
}
