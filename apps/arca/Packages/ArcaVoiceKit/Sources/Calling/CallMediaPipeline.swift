import Foundation
@preconcurrency import AVFoundation

/// Configuration for one call. Endpoints are injected so the relay can move
/// without touching the client.
public struct CallConfiguration: Sendable {
    public var signalingURL: URL
    public var relayHost: String
    public var relayPort: UInt16
    public var codec: CallCodecKind
    /// Send every frame twice, in two different datagrams. Doubles bitrate to
    /// ~80kbps and makes an isolated packet loss inaudible. On a mobile network
    /// this is the single cheapest quality win available, which is why it defaults
    /// on — 80kbps is nothing next to the video people stream on the subway.
    public var forwardErrorCorrection: Bool
    public var recordsAudio: Bool

    public init(signalingURL: URL,
                relayHost: String,
                relayPort: UInt16,
                codec: CallCodecKind = .aacELD,
                forwardErrorCorrection: Bool = true,
                recordsAudio: Bool = true) {
        self.signalingURL = signalingURL
        self.relayHost = relayHost
        self.relayPort = relayPort
        self.codec = codec
        self.forwardErrorCorrection = forwardErrorCorrection
        self.recordsAudio = recordsAudio
    }
}

/// The media hot path: mic → encode → wire, and wire → jitter buffer → decode →
/// speaker. Deliberately isolated from any UI so nothing on this path ever waits
/// on the main thread.
public final class CallMediaPipeline: @unchecked Sendable {
    /// Keep the playback ring topped up to this much audio. Absorbs the decode
    /// timer's scheduling wobble without adding meaningful latency.
    private static let playbackWatermarkMilliseconds: Double = 30

    private let configuration: CallConfiguration
    private let audio: CallAudioEngine
    private let encodeCodec: CallCodec
    private let decodeCodec: CallCodec
    private let jitterBuffer = CallJitterBuffer()
    private let monitor = CallQualityMonitor()
    private let recorder: CallRecorder?

    private var transport: CallMediaTransport?
    private let sendLock = NSLock()
    private var outboundSequence: UInt32 = 0
    private var pendingFrames: [CallFrame] = []
    private var previousFrames: [CallFrame] = []
    private var highestInboundSequence: UInt32 = 0

    private let decodeQueue = DispatchQueue(label: "com.thezone.arca.call.decode")
    private var decodeTimer: DispatchSourceTimer?
    private var qualityTimer: DispatchSourceTimer?

    private var onQuality: (@Sendable (CallQualitySnapshot) -> Void)?
    private var onTransportReady: (@Sendable (Bool) -> Void)?

    public init(configuration: CallConfiguration, recordingDirectory: URL?) throws {
        self.configuration = configuration
        self.audio = try CallAudioEngine()
        self.encodeCodec = try CallCodec(kind: configuration.codec)
        // A second codec instance for the receive side: AVAudioConverter is not
        // safe to drive from two queues, and encode runs on the mic tap while
        // decode runs on the decode timer.
        self.decodeCodec = try CallCodec(kind: configuration.codec)
        if configuration.recordsAudio, let directory = recordingDirectory {
            self.recorder = try? CallRecorder(directory: directory, format: audio.format)
        } else {
            self.recorder = nil
        }
    }

    public func start(roomCode: String, isCaller: Bool, keyBase64: String,
                      onQuality: @escaping @Sendable (CallQualitySnapshot) -> Void,
                      onTransportReady: @escaping @Sendable (Bool) -> Void) throws {
        self.onQuality = onQuality
        self.onTransportReady = onTransportReady

        let transport = try CallMediaTransport(relayHost: configuration.relayHost,
                                               relayPort: configuration.relayPort,
                                               roomCode: roomCode,
                                               isCaller: isCaller,
                                               keyBase64: keyBase64)
        self.transport = transport
        transport.start(onPacket: { [weak self] packet, byteCount, arrivedAt in
            self?.handleInbound(packet, byteCount: byteCount, arrivedAt: arrivedAt)
        }, onReadyChange: { ready in
            onTransportReady(ready)
        })

        try audio.start { [weak self] frame in
            self?.handleMicFrame(frame)
        }

        startDecodeLoop()
        startQualityLoop()
    }

    public func stop() -> CallRecorder.Result? {
        decodeTimer?.cancel()
        decodeTimer = nil
        qualityTimer?.cancel()
        qualityTimer = nil
        audio.stop()
        transport?.stop()
        transport = nil
        return recorder?.finish()
    }

    public var qualityReport: CallQualityReport { monitor.report() }
    public var currentQuality: CallQualitySnapshot { monitor.current }

    // MARK: - Send path

    private func handleMicFrame(_ buffer: AVAudioPCMBuffer) {
        recorder?.append(buffer, to: .me)

        let payload: Data
        do {
            payload = try encodeCodec.encode(buffer)
        } catch {
            CallTrace.log("pipeline: encode failed — \(error)")
            return
        }
        guard !payload.isEmpty else { return }

        sendLock.lock()
        let sequence = outboundSequence
        outboundSequence &+= 1
        pendingFrames.append(CallFrame(sequence: sequence, payload: payload))
        guard pendingFrames.count >= CallWire.framesPerPacket else {
            sendLock.unlock()
            return
        }
        let current = pendingFrames
        let redundant = configuration.forwardErrorCorrection ? previousFrames : []
        pendingFrames = []
        previousFrames = current
        let echoed = highestInboundSequence
        sendLock.unlock()

        // Fresh frames first so a truncated datagram still loses only the
        // insurance copy, never the primary.
        let packet = CallPacket(codec: configuration.codec,
                                sentAtMicros: CallClock.nowMicros(),
                                echoedSequence: echoed,
                                frames: current + redundant)
        let sentAt = CallClock.nowMicros()
        let byteCount = transport?.send(packet) ?? 0
        if byteCount > 0, let first = current.first {
            monitor.didSend(sequence: first.sequence, byteCount: byteCount, atMicros: sentAt)
        }
    }

    // MARK: - Receive path

    private func handleInbound(_ packet: CallPacket, byteCount: Int, arrivedAt: UInt64) {
        monitor.didReceive(byteCount: byteCount,
                           echoedSequence: packet.echoedSequence,
                           atMicros: arrivedAt)
        for frame in packet.frames {
            jitterBuffer.insert(sequence: frame.sequence,
                                payload: frame.payload,
                                sentAtMicros: packet.sentAtMicros,
                                arrivedAtMicros: arrivedAt)
            sendLock.lock()
            if frame.sequence > highestInboundSequence { highestInboundSequence = frame.sequence }
            sendLock.unlock()
        }
    }

    /// Tops the playback ring up to the watermark. Runs faster than the frame rate
    /// on purpose: pulling "as many frames as the ring needs" is self-correcting,
    /// where pulling "exactly one frame per tick" would drift with timer jitter.
    private func startDecodeLoop() {
        let timer = DispatchSource.makeTimerSource(queue: decodeQueue)
        timer.schedule(deadline: .now() + .milliseconds(5), repeating: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            var guardCount = 0
            while self.audio.playbackBacklogMilliseconds < Self.playbackWatermarkMilliseconds,
                  guardCount < 10 {
                guardCount += 1
                switch self.jitterBuffer.pop() {
                case .prebuffering:
                    return
                case .frame(_, let payload):
                    if let decoded = self.decodeCodec.decode(payload) {
                        self.audio.enqueueForPlayback(decoded)
                        self.recorder?.append(decoded, to: .them)
                    } else {
                        self.recorder?.appendSilence(sampleCount: CallWire.samplesPerFrame, to: .them)
                    }
                case .conceal:
                    // Silence for one 10ms frame. Short enough that the ear reads
                    // it as a tiny gap rather than a dropout.
                    self.audio.enqueueSilence(sampleCount: CallWire.samplesPerFrame)
                    self.recorder?.appendSilence(sampleCount: CallWire.samplesPerFrame, to: .them)
                }
            }
        }
        timer.resume()
        decodeTimer = timer
    }

    private func startQualityLoop() {
        let timer = DispatchSource.makeTimerSource(queue: decodeQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            var snapshot = self.monitor.tick(bufferStats: self.jitterBuffer.statistics())
            // Fold the playback ring into the latency figure so the HUD reports
            // what the ear hears, not what the network did.
            snapshot.jitterBufferMilliseconds += self.audio.playbackBacklogMilliseconds
            self.onQuality?(snapshot)
        }
        timer.resume()
        qualityTimer = timer
    }
}
