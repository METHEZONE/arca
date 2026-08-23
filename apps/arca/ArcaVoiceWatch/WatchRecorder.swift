import Foundation
import AVFoundation
import WatchKit

/// Records voice notes on the Watch and ships them to the iPhone for the
/// full transcription pipeline. AAC mono 24kHz keeps transfers small
/// (~20MB/hour) without hurting speech quality.
///
/// Surviving the wrist going down is the whole game here, so recording leans
/// on two independent layers:
///  1. `UIBackgroundModes: audio` — Apple's documented watchOS path for an
///     audio session started in the foreground to keep running once the app
///     backgrounds. This is the honest, on-label mechanism for a recorder.
///  2. `WKExtendedRuntimeSession` (see `WatchRuntimeGuard`) — insurance so the
///     process itself isn't suspended when the screen sleeps.
/// When the system takes layer 2 away we close the file and hand it to the
/// phone instead of letting the audio quietly evaporate. Anything that dies
/// harder than that leaves a file in Documents for `WatchSync.resendOrphans()`.
@MainActor
@Observable
final class WatchRecorder {
    private(set) var isRecording = false
    private(set) var startedAt: Date?
    var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private let runtime = WatchRuntimeGuard()

    func toggle() async {
        if isRecording {
            stopAndSend()
        } else {
            await start()
        }
    }

    func start() async {
        guard !isRecording else { return }
        errorMessage = nil

        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Microphone permission is required"
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)

            let url = WatchRecordingStore.newRecordingURL()
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: WatchRecordingStore.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: WatchRecordingStore.bitRate,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.record()
            self.recorder = recorder
            self.fileURL = url
            self.startedAt = .now
            isRecording = true

            runtime.onRuntimeEnding = { [weak self] in self?.stopAndSend(userInitiated: false) }
            runtime.start()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// `userInitiated: false` means the system pulled our runtime out from
    /// under us — same clean shutdown, different haptic, because the wrist
    /// needs to know the recording ended without being asked.
    func stopAndSend(userInitiated: Bool = true) {
        guard isRecording, let recorder, let fileURL else { return }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        // Cleared before invalidating the runtime session so the resulting
        // delegate callback can't re-enter this method.
        isRecording = false
        runtime.stop()
        let started = startedAt ?? .now
        startedAt = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        if !userInitiated {
            errorMessage = "Watch runtime ended — recording saved"
        }
        WKInterfaceDevice.current().play(userInitiated ? .click : .notification)
        WatchSync.shared.send(file: fileURL, duration: duration, createdAt: started)
        self.fileURL = nil
    }
}

// MARK: - Where recordings live

/// Recordings used to be written into `temporaryDirectory`, which the OS may
/// reclaim at any moment — including mid-recording under memory pressure, and
/// certainly once the app is force-quit. Documents is app-sandboxed and
/// non-purgeable, so a recording is durable from its first sample onward
/// (`AVAudioRecorder` streams to disk as it records rather than buffering to
/// the end).
enum WatchRecordingStore {
    static let sampleRate = 24_000
    static let bitRate = 48_000

    /// Recordings are only ever handed to the phone, never browsed on the
    /// Watch, so the flat Documents root is enough.
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    static func newRecordingURL() -> URL {
        directory.appendingPathComponent("watch-\(UUID().uuidString).m4a")
    }

    /// Recordings still sitting on disk with nobody to hand them over.
    /// Anything touched in the last minute is skipped: that is either an
    /// in-flight recording or one whose sender is still starting up.
    static func orphanedRecordings() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [] }

        let cutoff = Date.now.addingTimeInterval(-60)
        return files.filter { url in
            guard url.pathExtension == "m4a",
                  url.lastPathComponent.hasPrefix("watch-") else { return false }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return modified < cutoff
        }
    }

    static func createdAt(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .now
    }

    /// Bytes back into seconds at our fixed encoder bitrate. Deliberately not
    /// `AVURLAsset.duration`: an interrupted recording never got its MPEG-4
    /// index written, so AVFoundation reports nothing for exactly the files
    /// this is needed for.
    static func estimatedDuration(of url: URL) -> TimeInterval {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return Double(bytes) * 8 / Double(bitRate)
    }
}

// MARK: - Keeping the process alive

/// Holds a `WKExtendedRuntimeSession` open for the length of a recording.
///
/// PRODUCT / APP-REVIEW NOTE: watchOS has no general-purpose "let me keep
/// recording" session type. `WKExtendedRuntimeSession.session()` takes no
/// type argument at all — the capability comes from `WKBackgroundModes`, whose
/// only choices are `self-care` (10 min), `mindfulness` (1 hour),
/// `physical-therapy`, `alarm`, and `workout-processing`. We declare
/// `mindfulness`: it is the longest non-workout window and, unlike
/// `workout-processing`, needs no HealthKit entitlement and fabricates no
/// workout in the user's Fitness rings. It is still a semantic stretch for a
/// meeting recorder and carries a real review risk — flagged for product.
///
/// Nothing here is load-bearing on its own: if the session refuses to start,
/// `UIBackgroundModes: audio` remains the primary mechanism and recording
/// continues exactly as before.
@MainActor
final class WatchRuntimeGuard {
    /// Invoked when the system is about to take our runtime away — the last
    /// moment at which the recording can be closed cleanly and sent.
    var onRuntimeEnding: (() -> Void)?

    private var session: WKExtendedRuntimeSession?
    private var proxy: Proxy?

    func start() {
        guard session == nil else { return }
        // Swift imports WatchKit's `+session` factory as `init()`, which is
        // what grants the session the declared background mode's capabilities.
        let session = WKExtendedRuntimeSession()
        // The session holds its delegate weakly, so the proxy has to outlive
        // this call.
        let proxy = Proxy { [weak self] in self?.handleRuntimeEnding() }
        session.delegate = proxy
        self.session = session
        self.proxy = proxy
        session.start()
    }

    func stop() {
        session?.invalidate()
        session = nil
        proxy = nil
        onRuntimeEnding = nil
    }

    private func handleRuntimeEnding() {
        session = nil
        proxy = nil
        let ending = onRuntimeEnding
        onRuntimeEnding = nil
        ending?()
    }

    /// `WKExtendedRuntimeSessionDelegate` is an ObjC protocol, so it can't be
    /// worn by an `@Observable` type; this forwards to the guard instead.
    /// WatchKit delivers these callbacks on the main thread, and expiry has to
    /// be handled synchronously — an async hop may never get scheduled if the
    /// process is frozen first.
    private final class Proxy: NSObject, WKExtendedRuntimeSessionDelegate {
        private let runtimeEnding: @MainActor @Sendable () -> Void

        init(runtimeEnding: @escaping @MainActor @Sendable () -> Void) {
            self.runtimeEnding = runtimeEnding
        }

        func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
            NSLog("[ArcaVoice] watch: extended runtime session started, expires %@",
                  "\(extendedRuntimeSession.expirationDate.map(String.init(describing:)) ?? "unknown")")
        }

        func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
            // Renewing is not an option: starting a session requires the app
            // to be active, which it isn't in the case that matters (wrist
            // down). Close the recording while we still have the runtime to
            // finish writing the file and queue the transfer.
            NSLog("[ArcaVoice] watch: extended runtime session expiring — closing recording")
            let ending = runtimeEnding
            MainActor.assumeIsolated { ending() }
        }

        func extendedRuntimeSession(
            _ extendedRuntimeSession: WKExtendedRuntimeSession,
            didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
            error: Error?
        ) {
            NSLog("[ArcaVoice] watch: extended runtime session invalidated (reason %ld): %@",
                  reason.rawValue, "\(error.map(String.init(describing:)) ?? "no error")")
            // Losing frontmost status is not a reason to truncate: the audio
            // background mode is expected to carry the recording, and a file
            // left behind is swept up by `WatchSync.resendOrphans()` anyway.
            // Every other reason means the system is done giving us runtime.
            guard reason != .resignedFrontmost else { return }
            let ending = runtimeEnding
            MainActor.assumeIsolated { ending() }
        }
    }
}
