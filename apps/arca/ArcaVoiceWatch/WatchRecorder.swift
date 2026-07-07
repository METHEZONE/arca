import Foundation
import AVFoundation

/// Records voice notes on the Watch and ships them to the iPhone for the
/// full transcription pipeline. AAC mono 24kHz keeps transfers small
/// (~20MB/hour) without hurting speech quality.
@MainActor
@Observable
final class WatchRecorder {
    private(set) var isRecording = false
    private(set) var startedAt: Date?
    var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?

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

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("watch-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 48_000,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.record()
            self.recorder = recorder
            self.fileURL = url
            self.startedAt = .now
            isRecording = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopAndSend() {
        guard isRecording, let recorder, let fileURL else { return }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        isRecording = false
        let started = startedAt ?? .now
        startedAt = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        WatchSync.shared.send(file: fileURL, duration: duration, createdAt: started)
    }
}
