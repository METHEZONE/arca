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
            return L("마이크 권한이 필요해요. 시스템 설정 › 개인정보 보호 및 보안 › 마이크에서 ARCA를 켜주세요.",
                     "Microphone access is required. Turn on ARCA under System Settings › Privacy & Security › Microphone.")
        case .tapCreationFailed(let status):
            return L("상대방 소리(시스템 오디오)를 잡지 못했어요 (\(status)). 시스템 설정 › 개인정보 보호 및 보안 › 화면 및 시스템 오디오 녹음에서 ARCA를 켜주세요.",
                     "Couldn't capture system audio (\(status)). Turn on ARCA under System Settings › Privacy & Security › Screen & System Audio Recording.")
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
