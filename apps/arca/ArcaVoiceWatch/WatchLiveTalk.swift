import AVFoundation
import Foundation
import WatchKit

/// A live voice conversation with ARCA from the wrist, over OpenAI's Realtime
/// API. The watch never holds a key: the paired iPhone mints a short-lived
/// client secret (with ARCA's persona and memory baked into the session) and
/// hands it over; the watch streams microphone PCM up and plays ARCA's voice
/// back. Server-side turn detection does the listening/speaking dance, so the
/// user just talks.
@MainActor
@Observable
final class WatchLiveTalk {
    static let shared = WatchLiveTalk()

    enum Phase: Equatable {
        case idle
        case connecting
        /// ARCA is listening to the user.
        case listening
        /// ARCA is talking.
        case speaking
        case failed(String)
    }

    struct Turn: Codable, Sendable {
        let role: String
        let text: String
    }

    private(set) var phase: Phase = .idle
    /// 0…1, from ARCA's output audio — drives the body bounce.
    private(set) var speakingLevel: Double = 0
    /// What ARCA last said, for the one-line caption.
    private(set) var caption = ""
    private(set) var turns: [Turn] = []
    private var startedAt: Date?
    private var transport: LiveTalkTransport?

    var isActive: Bool {
        switch phase {
        case .connecting, .listening, .speaking: return true
        case .idle, .failed: return false
        }
    }

    func toggle() async {
        if isActive { stop() } else { await start() }
    }

    func start() async {
        guard !isActive else { return }
        phase = .connecting
        turns = []
        caption = ""
        speakingLevel = 0
        guard await AVAudioApplication.requestRecordPermission() else {
            fail(L("마이크 권한이 필요해요", "Microphone permission is required"))
            return
        }
        let secret: String
        do {
            secret = try await WatchSync.shared.requestRealtimeSecret()
        } catch {
            fail(error.localizedDescription)
            return
        }
        let transport = LiveTalkTransport(onEvent: { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        })
        transport.muted = !UserDefaults.standard.bool(forKey: "liveVoiceReplies") && UserDefaults.standard.object(forKey: "liveVoiceReplies") != nil
        do {
            try transport.start(secret: secret)
        } catch {
            transport.stop()
            fail(L("오디오를 열지 못했어요: \(error.localizedDescription)", "Couldn't open audio: \(error.localizedDescription)"))
            return
        }
        self.transport = transport
        startedAt = .now
        phase = .listening
        WKInterfaceDevice.current().play(.start)
    }

    func stop() {
        transport?.stop()
        transport = nil
        if !turns.isEmpty, let startedAt {
            WatchSync.shared.send(talk: turns.map { ["role": $0.role, "text": $0.text] }, startedAt: startedAt)
        }
        startedAt = nil
        speakingLevel = 0
        if case .failed = phase {} else { phase = .idle }
        WKInterfaceDevice.current().play(.stop)
    }

    /// Clears a failure so the next tap starts fresh.
    func dismissFailure() {
        if case .failed = phase { phase = .idle }
    }

    private func fail(_ message: String) {
        transport?.stop()
        transport = nil
        phase = .failed(message)
        WKInterfaceDevice.current().play(.failure)
    }

    private func handle(_ event: LiveTalkTransport.Event) {
        switch event {
        case .userSpeaking:
            speakingLevel = 0
            if isActive { phase = .listening }
        case .assistantAudio(let level):
            speakingLevel = level
            if isActive { phase = .speaking }
        case .assistantTranscript(let text):
            caption = text
            turns.append(Turn(role: "assistant", text: text))
        case .userTranscript(let text):
            turns.append(Turn(role: "user", text: text))
        case .responseFinished:
            speakingLevel = 0
            if isActive { phase = .listening }
        case .closed(let reason):
            if isActive {
                if let reason { fail(reason) } else { stop() }
            }
        }
    }
}

enum LiveTalkError: LocalizedError {
    case phoneUnreachable
    case phone(String)

    var errorDescription: String? {
        switch self {
        case .phoneUnreachable:
            return L("아이폰이 근처에 있어야 대화할 수 있어요", "Your iPhone needs to be nearby to talk")
        case .phone(let message):
            return message
        }
    }
}

/// Everything that touches audio threads or the socket, kept off the main
/// actor. Owns one AVAudioEngine (mic tap in, player out) and the WebSocket.
final class LiveTalkTransport: @unchecked Sendable {
    enum Event: Sendable {
        case userSpeaking
        case assistantAudio(level: Double)
        case assistantTranscript(String)
        case userTranscript(String)
        case responseFinished
        case closed(reason: String?)
    }

    private let onEvent: @Sendable (Event) -> Void
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let wireFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private let sendQueue = DispatchQueue(label: "com.thezone.arca.watch.livetalk")
    private var stopped = false
    /// Voice replies off: ARCA still answers (transcript, motion), just silently.
    var muted = false

    init(onEvent: @escaping @Sendable (Event) -> Void) {
        self.onEvent = onEvent
    }

    func start(secret: String) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        try session.setActive(true)

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let converter = AVAudioConverter(from: inputFormat, to: wireFormat) else {
            throw LiveTalkError.phone(L("마이크 형식을 읽지 못했어요", "Couldn't read the microphone format"))
        }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 2400, format: inputFormat) { [weak self] buffer, _ in
            self?.pushMic(buffer)
        }
        engine.prepare()
        try engine.start()
        player.volume = muted ? 0 : 1
        player.play()

        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime")!)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()
        // The secret carries persona + voice; this only pins the wire formats
        // and lets the server decide when a turn ends.
        send(json: [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "turn_detection": ["type": "server_vad"],
                        "transcription": ["model": "gpt-4o-mini-transcribe"],
                    ],
                    "output": ["format": ["type": "audio/pcm", "rate": 24_000]],
                ],
            ],
        ])
        receiveTask = Task { [weak self] in await self?.receiveLoop(task) }
    }

    func stop() {
        sendQueue.sync { stopped = true }
        receiveTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Microphone → socket

    private func pushMic(_ buffer: AVAudioPCMBuffer) {
        guard let converter, buffer.frameLength > 0 else { return }
        let ratio = wireFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let channel = out.int16ChannelData else { return }
        let data = Data(bytes: channel[0], count: Int(out.frameLength) * 2)
        send(json: ["type": "input_audio_buffer.append", "audio": data.base64EncodedString()])
    }

    private func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }
        sendQueue.async { [weak self] in
            guard let self, !self.stopped, let socket = self.socket else { return }
            socket.send(.string(text)) { _ in }
        }
    }

    // MARK: Socket → events / speaker

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let raw): data = raw
                @unknown default: continue
                }
                guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                handle(event)
            } catch {
                if !Task.isCancelled {
                    let closed = sendQueue.sync { stopped }
                    onEvent(.closed(reason: closed ? nil : L("연결이 끊어졌어요", "Connection dropped")))
                }
                return
            }
        }
    }

    private func handle(_ event: [String: Any]) {
        switch event["type"] as? String ?? "" {
        case "input_audio_buffer.speech_started":
            // Barge-in: the user started talking over ARCA — drop what's queued.
            player.stop()
            player.play()
            onEvent(.userSpeaking)
        case "response.output_audio.delta":
            guard let base64 = event["delta"] as? String, let pcm = Data(base64Encoded: base64) else { return }
            onEvent(.assistantAudio(level: schedule(pcm)))
        case "response.output_audio_transcript.done":
            if let transcript = event["transcript"] as? String, !transcript.isEmpty {
                onEvent(.assistantTranscript(transcript))
            }
        case "conversation.item.input_audio_transcription.completed":
            if let transcript = event["transcript"] as? String,
               !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onEvent(.userTranscript(transcript))
            }
        case "response.done":
            onEvent(.responseFinished)
        case "error":
            let message = (event["error"] as? [String: Any])?["message"] as? String ?? "error"
            onEvent(.closed(reason: message))
        default:
            break
        }
    }

    /// Queues one PCM16 chunk on the player and returns its loudness (0…1).
    private func schedule(_ pcm: Data) -> Double {
        let frames = pcm.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData?[0] else { return 0 }
        var sum: Double = 0
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                let value = Float(Int16(littleEndian: samples[i])) / 32768
                out[i] = value
                sum += Double(value * value)
            }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        player.scheduleBuffer(buffer)
        let rms = (sum / Double(frames)).squareRoot()
        return min(1, rms * 4)
    }
}
