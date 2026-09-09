import Foundation

/// Which physical source a buffer came from. Channel separation is the
/// structural basis of diarization: mic == the owner, system == everyone else.
public enum CaptureChannel: String, Codable, Sendable, CaseIterable {
    case microphone
    case systemAudio
    case mixed
}

/// A chunk of PCM audio flowing through the live pipeline.
public struct AudioChunk: Sendable {
    public let channel: CaptureChannel
    public let samples: [Float]
    public let sampleRate: Double
    /// Seconds since the start of the capture session.
    public let timestamp: TimeInterval

    public init(channel: CaptureChannel, samples: [Float], sampleRate: Double, timestamp: TimeInterval) {
        self.channel = channel
        self.samples = samples
        self.sampleRate = sampleRate
        self.timestamp = timestamp
    }
}

public struct CaptureConfig: Sendable {
    public var channels: Set<CaptureChannel>
    public var sampleRate: Double
    /// Directory where per-channel recordings are written.
    public var outputDirectory: URL

    public init(channels: Set<CaptureChannel>, sampleRate: Double = 16_000, outputDirectory: URL) {
        self.channels = channels
        self.sampleRate = sampleRate
        self.outputDirectory = outputDirectory
    }
}

/// Whether audio is actually reaching disk during a live capture.
///
/// The recording UI counts elapsed time off a start date, which keeps ticking
/// even after the audio engine has been torn down under it — a phone call, Siri,
/// a headset unplug, or another part of the app resetting the shared audio
/// session all stop the tap without stopping the clock. Capture reports its real
/// state here so the UI can say "paused" instead of quietly lying.
public enum CaptureHealth: Sendable, Equatable {
    /// Audio is flowing.
    case capturing
    /// Audio stopped and ARCA is trying to get it back. Everything written so
    /// far is safe on disk; the recording continues into the same file on resume.
    case interrupted(reason: String)
    /// Audio stopped and could not be recovered. The recording has to be
    /// finalized with whatever was captured up to that point.
    case stopped(reason: String)
}

/// Who owns the shared audio session right now.
///
/// On iOS there is exactly one `AVAudioSession` per process. Voice chat, TTS,
/// and session playback each used to reset its category unconditionally, which
/// reconfigures the session under a live `AVAudioEngine` and silently kills an
/// in-progress recording. A recording claims the session for its whole lifetime
/// and every other audio feature asks first.
public enum AudioSessionArbiter {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recordingClaims = 0

    /// True while a recording owns the session — do not change its category.
    public static var isRecordingClaimed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recordingClaims > 0
    }

    public static func claimForRecording() {
        lock.lock()
        recordingClaims += 1
        lock.unlock()
    }

    public static func releaseRecording() {
        lock.lock()
        recordingClaims = max(0, recordingClaims - 1)
        lock.unlock()
    }
}

/// Files produced by a finished capture, one per channel.
public struct CaptureArtifacts: Sendable {
    public let files: [CaptureChannel: URL]
    public let duration: TimeInterval

    public init(files: [CaptureChannel: URL], duration: TimeInterval) {
        self.files = files
        self.duration = duration
    }
}
