import Foundation
import ArcaVoiceCore

/// A running capture: live buffers for the streaming pipeline, files at the end.
public protocol CaptureSession: Sendable {
    /// Interleaved stream of buffers from all active channels.
    var buffers: AsyncStream<CapturedBuffer> { get }
    func stop() async throws -> CaptureArtifacts
}

public protocol AudioCaptureEngine: Sendable {
    /// Which channels this engine can record on this device.
    var availableChannels: Set<CaptureChannel> { get }
    func start(config: CaptureConfig) async throws -> any CaptureSession
}

public enum CaptureError: Error, LocalizedError {
    case microphonePermissionDenied
    case tapCreationFailed(OSStatus)
    case aggregateDeviceCreationFailed(OSStatus)
    case ioProcFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case fileCreationFailed(String)
    case formatUnavailable

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access is required. Allow ARCA to use the microphone in Settings."
        case .tapCreationFailed(let status):
            return "Couldn't create the system audio tap (\(status)). Check Settings > Privacy > Screen & System Audio Recording."
        case .aggregateDeviceCreationFailed(let status):
            return "Couldn't configure the audio device (\(status))"
        case .ioProcFailed(let status):
            return "Couldn't start audio IO (\(status))"
        case .deviceStartFailed(let status):
            return "Couldn't start the audio device (\(status))"
        case .fileCreationFailed(let reason):
            return "Couldn't create the recording file: \(reason)"
        case .formatUnavailable:
            return "Couldn't determine the audio format"
        }
    }
}
