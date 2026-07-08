import SwiftUI
import AVFoundation
import ArcaVoiceKit

/// Playback + cross-device transfer for a session's recording. Channel-split
/// sessions (mic + system audio) play both files in lockstep so the meeting
/// sounds whole again.
struct SessionAudioBar: View {
    let session: RecordingSession

    @State private var playback = SessionPlayback()
    @State private var relay = AudioRelay.shared

    private var localFiles: [URL] {
        session.audioAssets
            .map { SessionPaths.resolve(relativePath: $0.relativePath) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if localFiles.isEmpty {
                downloadRow
            } else {
                playerRow
                sendRow
            }
            statusRow
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .onDisappear { playback.stop() }
    }

    private var playerRow: some View {
        HStack(spacing: 12) {
            Button {
                playback.toggle(files: localFiles)
            } label: {
                Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)

            VStack(spacing: 3) {
                Slider(
                    value: Binding(
                        get: { playback.progress },
                        set: { playback.seek(to: $0) }),
                    in: 0...1)
                HStack {
                    Text(Duration.seconds(playback.currentTime).formatted(.time(pattern: .minuteSecond)))
                    Spacer()
                    Text(Duration.seconds(playback.duration).formatted(.time(pattern: .minuteSecond)))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private var sendRow: some View {
        Button {
            Task { await relay.upload(session: session) }
        } label: {
            Label("Send audio to my other devices", systemImage: "arrow.up.to.line.compact")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .disabled(isWorking)
    }

    private var downloadRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.slash")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording lives on another device")
                    .font(.subheadline.weight(.medium))
                Text("Pull it through your brain to re-listen here.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await relay.download(session: session) }
            } label: {
                if isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Download")
                        .font(.caption.weight(.semibold))
                }
            }
            .buttonStyle(.bordered)
            .disabled(isWorking)
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch relay.state(for: session.directoryName) {
        case .idle:
            EmptyView()
        case .working(let message):
            Label(message, systemImage: "arrow.triangle.2.circlepath")
                .font(.caption2).foregroundStyle(.secondary)
        case .done(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.orange)
        }
    }

    private var isWorking: Bool {
        if case .working = relay.state(for: session.directoryName) { return true }
        return false
    }
}

/// Plays 1..n audio files of one session in sync (mic + system channels).
@MainActor
@Observable
final class SessionPlayback: NSObject, AVAudioPlayerDelegate {
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 1

    @ObservationIgnored private var players: [AVAudioPlayer] = []
    @ObservationIgnored private var ticker: Task<Void, Never>?

    var progress: Double { duration > 0 ? min(1, currentTime / duration) : 0 }

    func toggle(files: [URL]) {
        if players.isEmpty {
            load(files: files)
        }
        guard let lead = players.first else { return }
        if isPlaying {
            players.forEach { $0.pause() }
            isPlaying = false
            ticker?.cancel()
        } else {
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            // Shared start time keeps split channels phase-locked.
            let startAt = lead.deviceCurrentTime + 0.05
            players.forEach { $0.play(atTime: startAt) }
            isPlaying = true
            tick()
        }
    }

    func seek(to fraction: Double) {
        guard duration > 0 else { return }
        let target = fraction * duration
        players.forEach { $0.currentTime = target }
        currentTime = target
    }

    func stop() {
        players.forEach { $0.stop() }
        players = []
        isPlaying = false
        ticker?.cancel()
    }

    private func load(files: [URL]) {
        players = files.compactMap { try? AVAudioPlayer(contentsOf: $0) }
        for player in players {
            player.delegate = self
            player.prepareToPlay()
        }
        duration = players.map(\.duration).max() ?? 1
    }

    private func tick() {
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let lead = self.players.first else { return }
                self.currentTime = lead.currentTime
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard players.allSatisfy({ !$0.isPlaying }) else { return }
            isPlaying = false
            currentTime = 0
            ticker?.cancel()
        }
    }
}
