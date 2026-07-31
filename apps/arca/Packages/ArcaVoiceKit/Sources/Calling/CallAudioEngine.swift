import Foundation
// AVAudioConverter's pull block is typed @Sendable but is documented to be called
// synchronously on the calling thread, and AVAudioPCMBuffer predates Sendable.
// @preconcurrency keeps that legacy API from spraying warnings over a file whose
// threading is already confined by hand.
@preconcurrency import AVFoundation

/// Full-duplex call audio.
///
/// The important line in this file is `setVoiceProcessingEnabled(true)`. It swaps
/// the engine onto Apple's VoiceProcessingIO unit — the same acoustic echo
/// cancellation, noise suppression and gain control FaceTime uses. Without it a
/// speakerphone call feeds itself back and sounds like a robot; with it we get
/// years of Apple DSP for free, which is the main reason a hand-rolled call app
/// can credibly beat a carrier's mVoIP path.
///
/// It is also why AirPods work here and not with PLAUD: the whole audio graph is
/// ours, so whatever route the user picks is just a route.
public final class CallAudioEngine: @unchecked Sendable {
    /// 48kHz mono float — matches the wire format so no resampling happens in the
    /// hot path.
    public let format: AVAudioFormat

    private let engine = AVAudioEngine()
    private let playbackBuffer: CallRingBuffer
    private var sourceNode: AVAudioSourceNode?
    private let converterLock = NSLock()
    private var micConverter: AVAudioConverter?
    private var pendingMicSamples: [Float] = []

    /// Called with exactly `CallWire.samplesPerFrame` samples, on the mic tap queue.
    private var onMicFrame: (@Sendable (AVAudioPCMBuffer) -> Void)?

    public init() throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: CallWire.sampleRate,
                                         channels: AVAudioChannelCount(CallWire.channelCount),
                                         interleaved: false) else {
            throw CallError.audioFormatUnavailable
        }
        self.format = format
        // Half a second of slack. Deep enough that a scheduling hiccup on the
        // decode side never starves the render thread, shallow enough that it
        // cannot silently accumulate latency.
        self.playbackBuffer = CallRingBuffer(capacity: Int(CallWire.sampleRate / 2))
        self.pendingMicSamples.reserveCapacity(CallWire.samplesPerFrame * 4)
    }

    public static func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    public func start(onMicFrame: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        self.onMicFrame = onMicFrame

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // .voiceChat is what tells iOS this is a call: it picks the call-tuned
        // input path, keeps Bluetooth on the HFP call profile, and lets the system
        // duck other audio the way it does for the Phone app.
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.allowBluetoothHFP, .defaultToSpeaker])
        // 10ms buffers. Asking for less buys nothing once the codec adds 15ms.
        try? session.setPreferredIOBufferDuration(CallWire.frameDuration)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let input = engine.inputNode
        // Enable on both ends of the graph: input gives us AEC/NS/AGC, output
        // makes sure the reference signal the canceller subtracts is the audio we
        // actually rendered.
        do {
            try input.setVoiceProcessingEnabled(true)
            try engine.outputNode.setVoiceProcessingEnabled(true)
            CallTrace.log("audio: voice processing enabled")
        } catch {
            // Not fatal — a call without AEC still works on a headset, it just
            // echoes on speakerphone. Worth knowing about in the log.
            CallTrace.log("audio: voice processing unavailable — \(error)")
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw CallError.audioFormatUnavailable }
        CallTrace.log("audio: mic \(inputFormat.sampleRate)Hz x\(inputFormat.channelCount)")
        micConverter = AVAudioConverter(from: inputFormat, to: format)

        let source = AVAudioSourceNode(format: format) { [playbackBuffer] _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let wanted = Int(frameCount)
            for index in 0..<buffers.count {
                guard let raw = buffers[index].mData else { continue }
                let pointer = raw.assumingMemoryBound(to: Float.self)
                _ = playbackBuffer.read(into: pointer, count: wanted)
                buffers[index].mDataByteSize = UInt32(wanted * MemoryLayout<Float>.size)
            }
            return noErr
        }
        self.sourceNode = source
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.handleMic(buffer)
        }

        engine.prepare()
        try engine.start()
        CallTrace.log("audio: engine started")
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let sourceNode {
            engine.detach(sourceNode)
            self.sourceNode = nil
        }
        playbackBuffer.reset()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        CallTrace.log("audio: engine stopped")
    }

    /// Queues decoded far-end audio for playback. Called from the decode timer.
    public func enqueueForPlayback(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        playbackBuffer.write(channel, count: Int(buffer.frameLength))
    }

    /// Queues a gap for a frame the network lost. Silence rather than a repeat of
    /// the previous frame: at 10ms a gap reads as a tiny pause, while a repeat
    /// reads as the metallic warble people describe as 지지직.
    public func enqueueSilence(sampleCount: Int) {
        let zeros = [Float](repeating: 0, count: sampleCount)
        zeros.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            playbackBuffer.write(base, count: sampleCount)
        }
    }

    /// Milliseconds of far-end audio currently waiting to be rendered. Part of the
    /// honest latency figure.
    public var playbackBacklogMilliseconds: Double {
        Double(playbackBuffer.availableToRead) / CallWire.sampleRate * 1_000
    }

    // MARK: - Private

    /// Converts the hardware's mic format to 48k mono and slices it into exact
    /// 10ms frames. The tap hands us whatever size it likes; the wire needs a
    /// fixed frame, so the remainder carries over between callbacks.
    private func handleMic(_ buffer: AVAudioPCMBuffer) {
        converterLock.lock()
        defer { converterLock.unlock() }

        guard let converter = micConverter else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }

        // The converter calls this block synchronously on our own thread, so the
        // one-shot flag never actually crosses a boundary. nonisolated(unsafe)
        // states that rather than pretending with a lock.
        nonisolated(unsafe) var handedOver = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            if handedOver {
                outStatus.pointee = .noDataNow
                return nil
            }
            handedOver = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = converted.floatChannelData?[0] else { return }

        pendingMicSamples.append(contentsOf: UnsafeBufferPointer(start: channel,
                                                                 count: Int(converted.frameLength)))

        while pendingMicSamples.count >= CallWire.samplesPerFrame {
            let slice = Array(pendingMicSamples.prefix(CallWire.samplesPerFrame))
            pendingMicSamples.removeFirst(CallWire.samplesPerFrame)
            guard let frame = AVAudioPCMBuffer(pcmFormat: format,
                                               frameCapacity: AVAudioFrameCount(CallWire.samplesPerFrame)),
                  let destination = frame.floatChannelData?[0] else { continue }
            slice.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                destination.update(from: base, count: CallWire.samplesPerFrame)
            }
            frame.frameLength = AVAudioFrameCount(CallWire.samplesPerFrame)
            onMicFrame?(frame)
        }
    }
}
