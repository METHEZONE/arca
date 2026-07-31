import Foundation

/// ARCA call trace log. Mirrors CaptureTrace's shape so call logs read the
/// same way capture logs do.
public enum CallTrace {
    nonisolated(unsafe) public static var isEnabled = true

    public static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        print("[arca.call] \(message())")
    }
}

public enum CallError: Error, Sendable {
    case audioFormatUnavailable
    case codecUnavailable(String)
    case transportFailed(String)
    case signalingFailed(String)
    case notConnected
}

/// How audio frames are carried on the wire.
///
/// AAC-ELD is the default: ~15ms algorithmic delay, transparent for speech at
/// 32-48kbps, and hardware-accelerated on every device ARCA runs on. PCM exists
/// as an escape hatch — on Wi-Fi it removes the codec from the equation, so a
/// bad-quality report can be blamed on the network instead of the encoder.
public enum CallCodecKind: String, Codable, Sendable, CaseIterable {
    case aacELD
    case pcm16

    public var label: String {
        switch self {
        case .aacELD: "AAC-ELD"
        case .pcm16: "PCM (uncompressed)"
        }
    }
}

/// Wire constants shared by both ends. Changing any of these is a breaking
/// protocol change, so they live in one place with the version byte.
public enum CallWire {
    /// Bumped whenever the packet layout changes.
    public static let version: UInt8 = 1

    /// 48kHz is what every Apple mic and every Bluetooth A2DP path can do, and
    /// it is AAC-ELD's sweet spot. Mono: a phone call has one talker.
    public static let sampleRate: Double = 48_000
    public static let channelCount: UInt32 = 1

    /// 480 samples = 10ms at 48kHz, which is AAC-ELD's native frame. Small
    /// frames keep loss damage small and latency low; the cost is header
    /// overhead, which we amortise by packing several frames per datagram.
    public static let samplesPerFrame: Int = 480
    public static let frameDuration: TimeInterval = Double(samplesPerFrame) / sampleRate

    /// Frames bundled into one datagram. 2 frames = 20ms per packet, the same
    /// packetisation VoLTE uses, so we inherit its loss/latency tradeoff.
    public static let framesPerPacket: Int = 2

    /// Keep datagrams well under the smallest MTU we might meet (IPv6 minimum
    /// is 1280) so nothing ever fragments on a carrier network.
    public static let maxDatagramSize: Int = 1100

    /// Target encoder bitrate. 40kbps AAC-ELD mono is clean speech; doubling it
    /// for redundancy still lands under 100kbps, cheaper than a video call.
    public static let encoderBitRate: Int = 40_000
}

/// One decodable audio frame plus the bookkeeping the receiver needs.
public struct CallFrame: Sendable {
    /// Monotonic frame counter from the sender. Drives ordering and loss maths.
    public let sequence: UInt32
    /// Encoded (or raw) audio payload.
    public let payload: Data

    public init(sequence: UInt32, payload: Data) {
        self.sequence = sequence
        self.payload = payload
    }
}

/// A decoded datagram: the frames it carried plus the sender's clock.
public struct CallPacket: Sendable {
    public let codec: CallCodecKind
    /// Sender's monotonic microsecond clock when the packet left. Used for
    /// one-way jitter, never for absolute time — the clocks are not synced.
    public let sentAtMicros: UInt64
    /// Highest sequence the sender had received from us when this left. Lets
    /// each side compute round-trip time without a separate ping.
    public let echoedSequence: UInt32
    public let frames: [CallFrame]

    public init(codec: CallCodecKind, sentAtMicros: UInt64,
                echoedSequence: UInt32, frames: [CallFrame]) {
        self.codec = codec
        self.sentAtMicros = sentAtMicros
        self.echoedSequence = echoedSequence
        self.frames = frames
    }
}

/// Binary codec for the media datagram.
///
/// Layout (all big-endian):
///   0      version (UInt8)
///   1      codec   (UInt8)
///   2      frameCount (UInt8)
///   3      reserved (UInt8)
///   4..11  sentAtMicros (UInt64)
///   12..15 echoedSequence (UInt32)
///   then frameCount × { sequence UInt32, length UInt16, payload }
public enum CallPacketCoder {
    static let headerSize = 16
    static let frameHeaderSize = 6

    public static func encode(_ packet: CallPacket) -> Data {
        var out = Data()
        out.reserveCapacity(CallWire.maxDatagramSize)
        out.append(CallWire.version)
        out.append(packet.codec == .aacELD ? 0 : 1)
        out.append(UInt8(min(packet.frames.count, 255)))
        out.append(0)
        out.appendBigEndian(packet.sentAtMicros)
        out.appendBigEndian(packet.echoedSequence)
        for frame in packet.frames {
            out.appendBigEndian(frame.sequence)
            out.appendBigEndian(UInt16(truncatingIfNeeded: frame.payload.count))
            out.append(frame.payload)
        }
        return out
    }

    public static func decode(_ data: Data) -> CallPacket? {
        guard data.count >= headerSize else { return nil }
        let bytes = [UInt8](data)
        guard bytes[0] == CallWire.version else { return nil }
        let codec: CallCodecKind = bytes[1] == 0 ? .aacELD : .pcm16
        let frameCount = Int(bytes[2])
        let sentAt = UInt64(bigEndian: bytes, at: 4)
        let echoed = UInt32(bigEndian: bytes, at: 12)

        var cursor = headerSize
        var frames: [CallFrame] = []
        frames.reserveCapacity(frameCount)
        for _ in 0..<frameCount {
            guard cursor + frameHeaderSize <= bytes.count else { return nil }
            let sequence = UInt32(bigEndian: bytes, at: cursor)
            let length = Int(UInt16(bigEndian: bytes, at: cursor + 4))
            cursor += frameHeaderSize
            guard cursor + length <= bytes.count else { return nil }
            frames.append(CallFrame(sequence: sequence,
                                    payload: Data(bytes[cursor..<(cursor + length)])))
            cursor += length
        }
        return CallPacket(codec: codec, sentAtMicros: sentAt,
                          echoedSequence: echoed, frames: frames)
    }
}

// MARK: - Big-endian helpers

extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) {
            append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    mutating func appendBigEndian(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }
}

extension UInt16 {
    init(bigEndian bytes: [UInt8], at offset: Int) {
        self = (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }
}

extension UInt32 {
    init(bigEndian bytes: [UInt8], at offset: Int) {
        var value: UInt32 = 0
        for index in 0..<4 { value = (value << 8) | UInt32(bytes[offset + index]) }
        self = value
    }
}

extension UInt64 {
    init(bigEndian bytes: [UInt8], at offset: Int) {
        var value: UInt64 = 0
        for index in 0..<8 { value = (value << 8) | UInt64(bytes[offset + index]) }
        self = value
    }
}

/// Monotonic microsecond clock. `Date` jumps when the system clock is corrected;
/// jitter maths must not.
public enum CallClock {
    public static func nowMicros() -> UInt64 {
        UInt64(DispatchTime.now().uptimeNanoseconds / 1_000)
    }
}
