import Foundation
import AVFoundation
import ArcaVoiceCore

/// The default capture engine for the current platform.
/// macOS: microphone + global system audio, channel-separated (the Granola-killer).
/// iOS: microphone only (the OS forbids system-audio capture).
public func makeDefaultCaptureEngine() -> any AudioCaptureEngine {
    #if os(macOS)
    return MeetingCaptureEngine()
    #else
    return MicOnlyCaptureEngine()
    #endif
}

final class ActiveCaptureSession: CaptureSession, @unchecked Sendable {
    let buffers: AsyncStream<CapturedBuffer>
    private let continuation: AsyncStream<CapturedBuffer>.Continuation
    private let onStop: @Sendable () async throws -> CaptureArtifacts

    init(onStop: @escaping @Sendable () async throws -> CaptureArtifacts) {
        var continuation: AsyncStream<CapturedBuffer>.Continuation!
        self.buffers = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation = $0 }
        self.continuation = continuation
        self.onStop = onStop
    }

    func yield(_ buffer: CapturedBuffer) {
        continuation.yield(buffer)
    }

    func stop() async throws -> CaptureArtifacts {
        let artifacts = try await onStop()
        continuation.finish()
        return artifacts
    }
}

public struct MicOnlyCaptureEngine: AudioCaptureEngine {
    public var availableChannels: Set<CaptureChannel> { [.microphone] }

    public init() {}

    public func start(config: CaptureConfig) async throws -> any CaptureSession {
        guard await MicCapture.requestPermission() else {
            throw CaptureError.microphonePermissionDenied
        }
        try FileManager.default.createDirectory(at: config.outputDirectory, withIntermediateDirectories: true)

        let mic = MicCapture()
        let session = ActiveCaptureSession(onStop: { @Sendable in
            guard let result = mic.stop() else {
                throw CaptureError.formatUnavailable
            }
            return CaptureArtifacts(files: [.microphone: result.url], duration: result.duration)
        })
        try mic.start(directory: config.outputDirectory) { captured in
            session.yield(captured)
        }
        return session
    }
}

#if os(macOS)
public struct MeetingCaptureEngine: AudioCaptureEngine {
    public var availableChannels: Set<CaptureChannel> { [.microphone, .systemAudio] }

    public init() {}

    public func start(config: CaptureConfig) async throws -> any CaptureSession {
        guard await MicCapture.requestPermission() else {
            throw CaptureError.microphonePermissionDenied
        }
        try FileManager.default.createDirectory(at: config.outputDirectory, withIntermediateDirectories: true)

        let mic = MicCapture()

        // System audio is set up first: its TCC prompt should appear before
        // recording starts, and activation failure must abort cleanly.
        let tap: SystemAudioTap?
        let systemWriter: ChannelWriter?
        if config.channels.contains(.systemAudio) {
            let activeTap = SystemAudioTap()
            try activeTap.activate()
            guard var asbd = activeTap.streamDescription,
                  let tapFormat = AVAudioFormat(streamDescription: &asbd) else {
                activeTap.stop()
                throw CaptureError.formatUnavailable
            }
            tap = activeTap
            systemWriter = try ChannelWriter(channel: .systemAudio, directory: config.outputDirectory,
                                             sourceFormat: tapFormat)
        } else {
            tap = nil
            systemWriter = nil
        }

        let session = ActiveCaptureSession(onStop: { @Sendable in
            tap?.stop()
            var files: [CaptureChannel: URL] = [:]
            var duration: TimeInterval = 0
            if let micResult = mic.stop() {
                files[.microphone] = micResult.url
                duration = micResult.duration
            }
            if let systemWriter {
                files[.systemAudio] = systemWriter.fileURL
                duration = max(duration, systemWriter.elapsed)
            }
            guard !files.isEmpty else { throw CaptureError.formatUnavailable }
            return CaptureArtifacts(files: files, duration: duration)
        })

        if let tap, let systemWriter {
            try tap.start { buffer in
                if let captured = systemWriter.write(buffer) {
                    session.yield(captured)
                }
            }
        }

        try mic.start(directory: config.outputDirectory) { captured in
            session.yield(captured)
        }
        return session
    }
}
#endif
