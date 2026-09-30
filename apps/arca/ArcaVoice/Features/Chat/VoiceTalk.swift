#if os(iOS)
import AVFoundation
import Foundation
import NaturalLanguage
import Speech
import ArcaVoiceKit

/// Voice conversation with ARCA: tap to talk (live on-device STT), release →
/// the text goes through the normal chat brain, and ARCA speaks the reply.
/// Separate from Record — this is a quick back-and-forth, not a session.
@MainActor
@Observable
final class VoiceTalk: NSObject {
    private(set) var isListening = false
    private(set) var isSpeaking = false
    private(set) var liveTranscript = ""
    var error: String?
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

    /// The system answers on a background queue. A closure written inside this
    /// @MainActor class inherits its isolation, and Swift 6 traps the moment
    /// the callback runs off the main thread — the first tap on the mic (or a
    /// hold on the home face) crashed the app. Nonisolated, it's just a value.
    nonisolated private static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    /// Same trap, audio thread: the tap runs on the render thread and the
    /// recognizer calls back on its own queue, so neither closure may be born
    /// inside this @MainActor class.
    nonisolated private static func feed(_ input: AVAudioInputNode, format: AVAudioFormat,
                                         into request: SFSpeechAudioBufferRecognitionRequest) {
        nonisolated(unsafe) let request = request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    nonisolated private static func recognize(
        _ recognizer: SFSpeechRecognizer, _ request: SFSpeechAudioBufferRecognitionRequest,
        update: @escaping @Sendable (String?, Bool, String?) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            if let error { DebugTrace.log("voice: recognizer ended — \(error.localizedDescription)") }
            update(result?.bestTranscription.formattedString, error != nil || (result?.isFinal ?? false),
                   error?.localizedDescription)
        }
    }

    /// Starts listening; live text lands in `liveTranscript`.
    func startListening() async {
        DebugTrace.log("voice: start (listening=\(isListening), recordingClaimed=\(AudioSessionArbiter.isRecordingClaimed))")
        guard !isListening else { return }
        // There is one AVAudioSession per process. Claiming it here with
        // `.measurement` mode reconfigures the session under the recording's live
        // AVAudioEngine, which stops the tap — the meeting keeps "recording" with
        // no audio reaching disk. A recording in progress wins.
        guard !AudioSessionArbiter.isRecordingClaimed else {
            error = "녹음 중에는 음성 대화를 쓸 수 없어요. 녹음을 멈춘 뒤 다시 시도해 주세요."
            return
        }
        error = nil
        liveTranscript = ""

        let speechStatus = await Self.speechAuthorization()
        DebugTrace.log("voice: speech auth \(speechStatus.rawValue)")
        guard speechStatus == .authorized else {
            error = L("음성 인식을 허용해 주세요. 설정 › ARCA에서 켤 수 있어요.",
                      "Allow speech recognition in Settings › ARCA.")
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            error = L("마이크를 허용해 주세요. 설정 › ARCA에서 켤 수 있어요.",
                      "Allow the microphone in Settings › ARCA.")
            return
        }

        stopSpeaking()
        // The language recordings turned out to be in, not the phone's.
        recognizer = SFSpeechRecognizer(locale: TranscriptionPrefs.liveLocale)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        DebugTrace.log("voice: recognizer \(recognizer?.locale.identifier ?? "nil") available=\(recognizer?.isAvailable ?? false)")
        guard let recognizer, recognizer.isAvailable else {
            error = L("지금은 음성 인식을 쓸 수 없어요. 잠시 뒤 다시 해 주세요.", "Speech recognition isn't available right now.")
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
            Self.feed(input, format: format, into: request)
            engine.prepare()
            try engine.start()
            isListening = true
            DebugTrace.log("voice: listening")

            task = Self.recognize(recognizer, request) { [weak self] text, ended, failure in
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.liveTranscript = text }
                    guard ended else { return }
                    // Dying before a single word used to just switch the mic
                    // off — say so, so it isn't read as "tapping does nothing".
                    if failure != nil, self.liveTranscript.isEmpty {
                        self.error = L("음성 인식을 시작하지 못했어요. 잠시 뒤 다시 눌러 주세요.",
                                       "Couldn't start listening. Try again in a moment.")
                    }
                    self.teardownAudio()
                }
            }
        } catch {
            self.error = L("듣기를 시작하지 못했어요: \(error.localizedDescription)", "Couldn't start listening: \(error.localizedDescription)")
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
        // Switching to `.playback` mid-recording deactivates the recording's
        // input route. The recording's own `.playAndRecord` + `.defaultToSpeaker`
        // session already plays out loud, so speak on top of it and leave the
        // category alone.
        if !AudioSessionArbiter.isRecordingClaimed {
            try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        let utterance = AVSpeechUtterance(string: String(clean.prefix(600)))
        utterance.voice = Self.voice(for: clean)
        utterance.rate = 0.5
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    /// Speak in the reply's own language — ARCA answers in Korean as often as
    /// English, and Hangul through an English voice is noise, not speech.
    private static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let code = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? "en"
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(code) }
        return candidates.first { $0.quality == .premium }
            ?? candidates.first { $0.quality == .enhanced }
            ?? candidates.first
            ?? AVSpeechSynthesisVoice(language: "en-US")
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
