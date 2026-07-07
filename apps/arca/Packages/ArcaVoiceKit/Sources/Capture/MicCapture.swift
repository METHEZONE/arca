import Foundation
import AVFoundation
import ArcaVoiceCore

/// Microphone capture via AVAudioEngine — works on macOS and iOS.
final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var writer: ChannelWriter?

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start(directory: URL, onBuffer: @escaping (CapturedBuffer) -> Void) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        #endif

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw CaptureError.formatUnavailable }

        let writer = try ChannelWriter(channel: .microphone, directory: directory, sourceFormat: format)
        self.writer = writer

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            if let captured = writer.write(buffer) {
                onBuffer(captured)
            }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() -> (url: URL, duration: TimeInterval)? {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        guard let writer else { return nil }
        return (writer.fileURL, writer.elapsed)
    }
}
