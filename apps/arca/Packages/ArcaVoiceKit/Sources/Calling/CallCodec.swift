import Foundation
@preconcurrency import AVFoundation

/// Encodes and decodes one call's audio frames.
///
/// AAC-ELD (Enhanced Low Delay) is the format here because it is the only
/// conversational codec Apple ships in the SDK: ~15ms algorithmic delay against
/// AAC-LC's ~100ms+, hardware-accelerated, and transparent for speech at 40kbps.
/// That is what lets this beat AMR-WB — VoLTE tops out at 16kHz sampling while
/// this carries the full 48kHz band.
///
/// Confine each instance to a single queue. The encoder lives on the mic tap
/// queue, the decoder on the render queue, so they never contend.
public final class CallCodec: @unchecked Sendable {
    public let kind: CallCodecKind
    public let pcmFormat: AVAudioFormat

    private let compressedFormat: AVAudioFormat?
    private let encoder: AVAudioConverter?
    private let decoder: AVAudioConverter?
    private let lock = NSLock()

    public init(kind: CallCodecKind) throws {
        self.kind = kind

        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: CallWire.sampleRate,
                                      channels: AVAudioChannelCount(CallWire.channelCount),
                                      interleaved: false) else {
            throw CallError.audioFormatUnavailable
        }
        self.pcmFormat = pcm

        guard kind == .aacELD else {
            self.compressedFormat = nil
            self.encoder = nil
            self.decoder = nil
            return
        }

        // Built by hand rather than via AVAudioFormat(settings:) — for compressed
        // formats the settings initialiser is inconsistent about which keys it
        // honours, and getting mFramesPerPacket wrong silently changes the frame
        // size out from under the wire protocol.
        var description = AudioStreamBasicDescription(
            mSampleRate: CallWire.sampleRate,
            mFormatID: kAudioFormatMPEG4AAC_ELD,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(CallWire.samplesPerFrame),
            mBytesPerFrame: 0,
            mChannelsPerFrame: CallWire.channelCount,
            mBitsPerChannel: 0,
            mReserved: 0)
        guard let compressed = AVAudioFormat(streamDescription: &description) else {
            throw CallError.codecUnavailable("AAC-ELD format unavailable")
        }
        self.compressedFormat = compressed

        guard let encoder = AVAudioConverter(from: pcm, to: compressed) else {
            throw CallError.codecUnavailable("AAC-ELD encoder unavailable")
        }
        encoder.bitRate = CallWire.encoderBitRate
        self.encoder = encoder

        guard let decoder = AVAudioConverter(from: compressed, to: pcm) else {
            throw CallError.codecUnavailable("AAC-ELD decoder unavailable")
        }
        self.decoder = decoder

        CallTrace.log("codec: AAC-ELD ready at \(CallWire.encoderBitRate / 1000)kbps, "
                      + "\(CallWire.samplesPerFrame) frames/packet")
    }

    /// Encodes exactly `CallWire.samplesPerFrame` samples.
    public func encode(_ buffer: AVAudioPCMBuffer) throws -> Data {
        guard kind == .aacELD else { return Self.packPCM16(buffer) }
        guard let encoder, let compressedFormat else { throw CallError.codecUnavailable("no encoder") }

        lock.lock()
        defer { lock.unlock() }

        let out = AVAudioCompressedBuffer(format: compressedFormat,
                                          packetCapacity: 1,
                                          maximumPacketSize: encoder.maximumOutputPacketSize)
        // The converter calls this block synchronously on our own thread, so the
        // one-shot flag never actually crosses a boundary. nonisolated(unsafe)
        // states that rather than pretending with a lock.
        nonisolated(unsafe) var handedOver = false
        var conversionError: NSError?
        let status = encoder.convert(to: out, error: &conversionError) { _, outStatus in
            if handedOver {
                outStatus.pointee = .noDataNow
                return nil
            }
            handedOver = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            throw CallError.codecUnavailable(conversionError?.localizedDescription ?? "encode failed")
        }
        guard out.byteLength > 0 else { return Data() }
        return Data(bytes: out.data, count: Int(out.byteLength))
    }

    /// Decodes one frame back to PCM. Returns nil if the payload is unusable, so
    /// the caller can conceal instead of playing noise.
    public func decode(_ payload: Data) -> AVAudioPCMBuffer? {
        guard !payload.isEmpty else { return nil }
        guard kind == .aacELD else { return Self.unpackPCM16(payload, format: pcmFormat) }
        guard let decoder, let compressedFormat else { return nil }

        lock.lock()
        defer { lock.unlock() }

        let input = AVAudioCompressedBuffer(format: compressedFormat,
                                            packetCapacity: 1,
                                            maximumPacketSize: payload.count)
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(input.data, base, payload.count)
        }
        input.byteLength = UInt32(payload.count)
        input.packetCount = 1
        input.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: UInt32(CallWire.samplesPerFrame),
            mDataByteSize: UInt32(payload.count))

        guard let out = AVAudioPCMBuffer(pcmFormat: pcmFormat,
                                          frameCapacity: AVAudioFrameCount(CallWire.samplesPerFrame)) else {
            return nil
        }
        // The converter calls this block synchronously on our own thread, so the
        // one-shot flag never actually crosses a boundary. nonisolated(unsafe)
        // states that rather than pretending with a lock.
        nonisolated(unsafe) var handedOver = false
        var conversionError: NSError?
        let status = decoder.convert(to: out, error: &conversionError) { _, outStatus in
            if handedOver {
                outStatus.pointee = .noDataNow
                return nil
            }
            handedOver = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error || out.frameLength == 0 {
            CallTrace.log("codec: decode failed — \(conversionError?.localizedDescription ?? "empty")")
            return nil
        }
        return out
    }

    // MARK: - PCM escape hatch

    /// 16-bit little-endian mono. 768kbps, so Wi-Fi only — but it removes the
    /// encoder from the picture when we need to know whether a bad call is the
    /// network's fault or the codec's.
    private static func packPCM16(_ buffer: AVAudioPCMBuffer) -> Data {
        guard let channel = buffer.floatChannelData?[0] else { return Data() }
        let count = Int(buffer.frameLength)
        var out = Data(capacity: count * 2)
        for index in 0..<count {
            let clamped = max(-1.0, min(1.0, channel[index]))
            let value = Int16(clamped * 32_767)
            out.append(UInt8(truncatingIfNeeded: UInt16(bitPattern: value)))
            out.append(UInt8(truncatingIfNeeded: UInt16(bitPattern: value) >> 8))
        }
        return out
    }

    private static func unpackPCM16(_ data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleCount = data.count / 2
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(sampleCount)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        let bytes = [UInt8](data)
        for index in 0..<sampleCount {
            let raw = UInt16(bytes[index * 2]) | (UInt16(bytes[index * 2 + 1]) << 8)
            channel[index] = Float(Int16(bitPattern: raw)) / 32_767
        }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        return buffer
    }
}
