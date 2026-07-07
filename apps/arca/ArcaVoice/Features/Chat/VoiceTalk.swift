#if os(iOS)
import AVFoundation
import Foundation
import Speech

/// Voice conversation with ARCA: tap to talk (live on-device STT), release →
/// the text goes through the normal chat brain, and ARCA speaks the reply.
/// Separate from Record — this is a quick back-and-forth, not a session.
@MainActor
@Observable
final class VoiceTalk: NSObject {
    private(set) var isListening = false
    private(set) var isSpeaking = false
    private(set) var liveTranscript = ""
    private(set) var error: String?
    /// While on, assistant replies are spoken aloud.
    var voiceRepliesOn = false

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Starts listening; live text lands in `liveTranscript`.
    func startListening() async {
        guard !isListening else { return }
        error = nil
        liveTranscript = ""

        let auth = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard auth == .authorized else {
            error = "Speech recognition permission needed — allow it in Settings."
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            error = "Microphone permission needed."
            return
        }

        stopSpeaking()
        recognizer = SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            error = "Speech recognition unavailable right now."
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
            isListening = true

            task = recognizer.recognitionTask(with: request) { [weak self] result, err in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.liveTranscript = result.bestTranscription.formattedString
                    }
                    if err != nil || (result?.isFinal ?? false) {
                        self.teardownAudio()
                    }
                }
            }
        } catch {
            self.error = "Couldn't start listening: \(error.localizedDescription)"
            teardownAudio()
        }
    }

    /// Stops listening and returns whatever was heard.
    @discardableResult
    func stopListening() -> String {
        request?.endAudio()
        teardownAudio()
        let text = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        liveTranscript = ""
        return text
    }

    private func teardownAudio() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        task?.cancel()
        task = nil
        request = nil
        isListening = false
    }

    // MARK: - Speaking

    /// Reads a reply aloud (markdown chrome stripped for the ear).
    func speak(_ text: String) {
        let clean = text
            .replacingOccurrences(of: #"[*_#`>\[\]()-]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        stopSpeaking()
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: String(clean.prefix(600)))
        let premium = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") && $0.quality == .premium }
            .first
        utterance.voice = premium ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.5
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }
}

extension VoiceTalk: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
#endif
