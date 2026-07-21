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

/// Bring-up trace hook — the app points this at its trace file so capture
/// failures are diagnosable outside Xcode (unified log is unreliable here).
public enum CaptureTrace {
    nonisolated(unsafe) public static var sink: (@Sendable (String) -> Void)?
    static func log(_ message: String) { sink?(message) }
}

#if os(macOS)
public struct MeetingCaptureEngine: AudioCaptureEngine {
    /// True when the most recent start had to drop the system-audio channel
    /// (TCC denied, tap failure) and recorded mic-only instead.
    nonisolated(unsafe) public static var lastStartDroppedSystemAudio = false

    public var availableChannels: Set<CaptureChannel> { [.microphone, .systemAudio] }

    public init() {}

    public func start(config: CaptureConfig) async throws -> any CaptureSession {
        guard await MicCapture.requestPermission() else {
            CaptureTrace.log("meeting start: mic permission denied")
            throw CaptureError.microphonePermissionDenied
        }
        try FileManager.default.createDirectory(at: config.outputDirectory, withIntermediateDirectories: true)

        let mic = MicCapture()

        // The other side's audio is a bonus, not the recording: if the tap
        // can't come up (audio-capture TCC denied, aggregate device failure),
        // degrade to mic-only instead of killing the whole meeting.
        Self.lastStartDroppedSystemAudio = false
        var tap: SystemAudioTap?
        var systemWriter: ChannelWriter?
        if config.channels.contains(.systemAudio) {
            do {
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
                CaptureTrace.log("meeting start: system-audio tap active")
            } catch {
                CaptureTrace.log("meeting start: system-audio tap failed (\(error)) — mic-only")
                tap?.stop()
                tap = nil
                systemWriter = nil
                Self.lastStartDroppedSystemAudio = true
            }
        }

        // Freeze for the @Sendable stop closure (vars can't be captured).
        let activeTap = tap
        let activeWriter = systemWriter

        let session = ActiveCaptureSession(onStop: { @Sendable in
            activeTap?.stop()
            var files: [CaptureChannel: URL] = [:]
            var duration: TimeInterval = 0
            if let micResult = mic.stop() {
                files[.microphone] = micResult.url
                duration = micResult.duration
            }
            if let activeWriter {
                files[.systemAudio] = activeWriter.fileURL
                duration = max(duration, activeWriter.elapsed)
            }
            guard !files.isEmpty else { throw CaptureError.formatUnavailable }
            return CaptureArtifacts(files: files, duration: duration)
        })

        if let activeTap, let activeWriter {
            do {
                try activeTap.start { buffer in
                    if let captured = activeWriter.write(buffer) {
                        session.yield(captured)
                    }
                }
            } catch {
                CaptureTrace.log("meeting start: tap IO failed (\(error)) — mic-only")
                activeTap.stop()
                Self.lastStartDroppedSystemAudio = true
            }
        }

        try mic.start(directory: config.outputDirectory) { captured in
            session.yield(captured)
        }
        CaptureTrace.log("meeting start: mic running")
        return session
    }
}
#endif
