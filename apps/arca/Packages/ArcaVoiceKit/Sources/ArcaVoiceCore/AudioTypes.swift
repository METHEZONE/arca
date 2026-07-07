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

/// Files produced by a finished capture, one per channel.
public struct CaptureArtifacts: Sendable {
    public let files: [CaptureChannel: URL]
    public let duration: TimeInterval

    public init(files: [CaptureChannel: URL], duration: TimeInterval) {
        self.files = files
        self.duration = duration
    }
}
