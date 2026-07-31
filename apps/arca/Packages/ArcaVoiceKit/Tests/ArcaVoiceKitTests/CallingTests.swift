import XCTest
@testable import Calling

/// The jitter buffer and the wire format decide whether a call sounds like a call.
/// Both are pure logic on purpose so the behaviour that produces 지지직 can be
/// pinned down here instead of guessed at on a subway platform.
final class CallWireTests: XCTestCase {
    private func packet(sequences: [UInt32], sentAt: UInt64 = 1_000) -> CallPacket {
        CallPacket(codec: .aacELD,
                   sentAtMicros: sentAt,
                   echoedSequence: 42,
                   frames: sequences.map { CallFrame(sequence: $0, payload: Data([UInt8($0 % 251), 0xAB, 0xCD])) })
    }

    func testRoundTripPreservesEveryField() throws {
        let original = packet(sequences: [7, 8, 5, 6], sentAt: 9_876_543_210)
        let decoded = try XCTUnwrap(CallPacketCoder.decode(CallPacketCoder.encode(original)))

        XCTAssertEqual(decoded.codec, .aacELD)
        XCTAssertEqual(decoded.sentAtMicros, 9_876_543_210)
        XCTAssertEqual(decoded.echoedSequence, 42)
        XCTAssertEqual(decoded.frames.map(\.sequence), [7, 8, 5, 6])
        XCTAssertEqual(decoded.frames.map(\.payload), original.frames.map(\.payload))
    }

    func testPcmCodecFlagSurvives() throws {
        let original = CallPacket(codec: .pcm16, sentAtMicros: 1, echoedSequence: 0,
                                  frames: [CallFrame(sequence: 0, payload: Data([1, 2]))])
        let decoded = try XCTUnwrap(CallPacketCoder.decode(CallPacketCoder.encode(original)))
        XCTAssertEqual(decoded.codec, .pcm16)
    }

    /// A truncated datagram must be rejected rather than half-decoded — a partial
    /// frame fed to the decoder is how you get a burst of noise in someone's ear.
    func testTruncatedDatagramIsRejected() {
        let encoded = CallPacketCoder.encode(packet(sequences: [1, 2]))
        for cut in 1..<encoded.count {
            let truncated = encoded.prefix(cut)
            if let decoded = CallPacketCoder.decode(Data(truncated)) {
                XCTAssertEqual(decoded.frames.count, Int(encoded[2]),
                               "accepted a short datagram at \(cut) bytes without all frames")
            }
        }
    }

    func testWrongVersionIsRejected() {
        var encoded = CallPacketCoder.encode(packet(sequences: [1]))
        encoded[0] = 99
        XCTAssertNil(CallPacketCoder.decode(encoded))
    }

    func testEmptyDataIsRejected() {
        XCTAssertNil(CallPacketCoder.decode(Data()))
    }

    /// Two frames per datagram plus the redundant copy has to stay inside the
    /// smallest MTU we might meet, or carriers will fragment voice packets.
    func testFullRedundantPacketFitsInOneDatagram() {
        // 40kbps at 10ms frames is ~50 bytes; allow generous headroom per frame.
        let fat = Data(repeating: 0xFF, count: 120)
        let frames = (0..<UInt32(CallWire.framesPerPacket * 2)).map {
            CallFrame(sequence: $0, payload: fat)
        }
        let encoded = CallPacketCoder.encode(
            CallPacket(codec: .aacELD, sentAtMicros: 0, echoedSequence: 0, frames: frames))
        XCTAssertLessThan(encoded.count, CallWire.maxDatagramSize)
    }
}

final class CallJitterBufferTests: XCTestCase {
    private let frameMicros = UInt64(CallWire.frameDuration * 1_000_000)

    private func makeBuffer(minimumFrames: Int = 2) -> CallJitterBuffer {
        var config = CallJitterBuffer.Configuration()
        config.minimumFrames = minimumFrames
        return CallJitterBuffer(configuration: config)
    }

    private func payload(_ sequence: UInt32) -> Data { Data([UInt8(sequence % 251)]) }

    /// Feeds frames on a perfectly regular clock.
    private func fill(_ buffer: CallJitterBuffer, sequences: [UInt32], startAt: UInt64 = 100_000) {
        for sequence in sequences {
            let at = startAt + UInt64(sequence) * frameMicros
            buffer.insert(sequence: sequence, payload: payload(sequence),
                          sentAtMicros: at, arrivedAtMicros: at)
        }
    }

    func testHoldsBackUntilPrebufferIsMet() {
        let buffer = makeBuffer(minimumFrames: 3)
        fill(buffer, sequences: [0, 1])
        XCTAssertEqual(buffer.pop(), .prebuffering)

        fill(buffer, sequences: [2])
        XCTAssertEqual(buffer.pop(), .frame(sequence: 0, payload: payload(0)))
        XCTAssertEqual(buffer.pop(), .frame(sequence: 1, payload: payload(1)))
    }

    func testDeliversInOrderDespiteReorderedArrival() {
        let buffer = makeBuffer()
        // 1 arrives after 2 — routine on a mobile network.
        fill(buffer, sequences: [0, 2, 1])
        XCTAssertEqual(buffer.pop(), .frame(sequence: 0, payload: payload(0)))
        XCTAssertEqual(buffer.pop(), .frame(sequence: 1, payload: payload(1)))
        XCTAssertEqual(buffer.pop(), .frame(sequence: 2, payload: payload(2)))
    }

    /// The redundancy scheme sends every frame twice on purpose. The second copy
    /// must be free — counted, but never played twice.
    func testDuplicateFrameIsCountedNotPlayedTwice() {
        let buffer = makeBuffer()
        fill(buffer, sequences: [0, 1])
        buffer.insert(sequence: 0, payload: payload(0),
                      sentAtMicros: 100_000, arrivedAtMicros: 100_100)
        XCTAssertEqual(buffer.statistics().duplicates, 1)

        XCTAssertEqual(buffer.pop(), .frame(sequence: 0, payload: payload(0)))
        XCTAssertEqual(buffer.pop(), .frame(sequence: 1, payload: payload(1)))
        XCTAssertEqual(buffer.pop(), .prebuffering, "a duplicate must not add a frame")
    }

    /// A genuinely lost frame with newer audio behind it must be concealed and
    /// stepped over, not waited for.
    func testMissingFrameIsConcealedWhenNewerAudioExists() {
        let buffer = makeBuffer()
        fill(buffer, sequences: [0, 1, 3, 4])
        XCTAssertEqual(buffer.pop(), .frame(sequence: 0, payload: payload(0)))
        XCTAssertEqual(buffer.pop(), .frame(sequence: 1, payload: payload(1)))
        XCTAssertEqual(buffer.pop(), .conceal(sequence: 2))
        XCTAssertEqual(buffer.pop(), .frame(sequence: 3, payload: payload(3)))
        XCTAssertEqual(buffer.statistics().concealed, 1)
    }

    /// Running dry is different from losing a frame: we outran the network, so go
    /// back to prebuffering instead of concealing forever.
    func testEmptyBufferReturnsToPrebufferingAndDeepens() {
        let buffer = makeBuffer()
        fill(buffer, sequences: [0, 1])
        _ = buffer.pop()
        _ = buffer.pop()
        let before = buffer.statistics().targetFrames

        XCTAssertEqual(buffer.pop(), .prebuffering)
        let stats = buffer.statistics()
        XCTAssertEqual(stats.underruns, 1)
        XCTAssertGreaterThan(stats.targetFrames, before, "an underrun must deepen the buffer")
        XCTAssertEqual(stats.concealed, 0, "an underrun is not a lost frame")
    }

    func testFrameArrivingAfterItsSlotIsCountedLate() {
        let buffer = makeBuffer()
        fill(buffer, sequences: [0, 1, 3, 4])
        _ = buffer.pop()          // 0
        _ = buffer.pop()          // 1
        _ = buffer.pop()          // conceal 2
        // 2 shows up now — too late to be useful.
        buffer.insert(sequence: 2, payload: payload(2),
                      sentAtMicros: 100_000, arrivedAtMicros: 900_000)
        XCTAssertEqual(buffer.statistics().late, 1)
        XCTAssertEqual(buffer.pop(), .frame(sequence: 3, payload: payload(3)))
    }

    /// The whole reason the buffer is adaptive: a jittery network must push the
    /// target depth up, or every burst turns into a dropout.
    func testJitterDeepensTheTargetBuffer() {
        let steady = makeBuffer()
        fill(steady, sequences: Array(0..<40))
        let steadyTarget = steady.statistics().targetFrames

        let jittery = makeBuffer()
        var arrival: UInt64 = 100_000
        for sequence in UInt32(0)..<40 {
            let sent = 100_000 + UInt64(sequence) * frameMicros
            // Alternate between early and very late — 60ms of swing.
            arrival += frameMicros + (sequence % 2 == 0 ? 60_000 : 0)
            jittery.insert(sequence: sequence, payload: payload(sequence),
                           sentAtMicros: sent, arrivedAtMicros: arrival)
        }
        let jitteryStats = jittery.statistics()
        XCTAssertGreaterThan(jitteryStats.targetFrames, steadyTarget)
        XCTAssertGreaterThan(jitteryStats.jitterMilliseconds, 5)
    }

    func testTargetNeverExceedsTheCeiling() {
        var config = CallJitterBuffer.Configuration()
        config.maximumFrames = 6
        let buffer = CallJitterBuffer(configuration: config)
        var arrival: UInt64 = 100_000
        for sequence in UInt32(0)..<60 {
            arrival += frameMicros + UInt64.random(in: 0...400_000)
            buffer.insert(sequence: sequence, payload: payload(sequence),
                          sentAtMicros: 100_000 + UInt64(sequence) * frameMicros,
                          arrivedAtMicros: arrival)
        }
        XCTAssertLessThanOrEqual(buffer.statistics().targetFrames, 6)
    }

    func testLossRateCountsConcealedAgainstExpected() {
        let buffer = makeBuffer()
        fill(buffer, sequences: [0, 1, 2, 4])
        _ = buffer.pop(); _ = buffer.pop(); _ = buffer.pop()
        _ = buffer.pop()  // conceal 3
        let stats = buffer.statistics()
        XCTAssertEqual(stats.concealed, 1)
        XCTAssertEqual(stats.lossRate, 1.0 / 5.0, accuracy: 0.0001)
    }
}

final class CallQualityTests: XCTestCase {
    private func snapshot(loss: Double, roundTrip: Double, buffer: Double) -> CallQualitySnapshot {
        var value = CallQualitySnapshot()
        value.lossRate = loss
        value.roundTripMilliseconds = roundTrip
        value.jitterBufferMilliseconds = buffer
        return value
    }

    /// A clean local call should score above a normal cellular call, which is the
    /// entire premise of building this instead of using 에이닷.
    func testCleanCallScoresAboveTypicalCellular() {
        let clean = snapshot(loss: 0, roundTrip: 40, buffer: 30)
        XCTAssertGreaterThan(clean.estimatedMOS, 4.0)
    }

    func testLossDominatesTheScore() {
        let clean = snapshot(loss: 0, roundTrip: 60, buffer: 40)
        let lossy = snapshot(loss: 0.05, roundTrip: 60, buffer: 40)
        XCTAssertGreaterThan(clean.estimatedMOS, lossy.estimatedMOS + 0.5)
    }

    func testHighLatencyIsPenalised() {
        let near = snapshot(loss: 0, roundTrip: 40, buffer: 30)
        let far = snapshot(loss: 0, roundTrip: 400, buffer: 200)
        XCTAssertGreaterThan(near.estimatedMOS, far.estimatedMOS)
    }

    func testMosStaysInsideTheScale() {
        for loss in [0.0, 0.01, 0.1, 0.5, 1.0] {
            for roundTrip in [0.0, 100.0, 1_000.0, 5_000.0] {
                let mos = snapshot(loss: loss, roundTrip: roundTrip, buffer: 50).estimatedMOS
                XCTAssertGreaterThanOrEqual(mos, 1.0)
                XCTAssertLessThanOrEqual(mos, 4.5)
            }
        }
    }

    /// Latency has to include the buffer we chose to hold, otherwise a deep buffer
    /// would flatter the score while the conversation gets harder.
    func testOneWayLatencyIncludesBufferAndCodec() {
        let value = snapshot(loss: 0, roundTrip: 100, buffer: 60)
        XCTAssertEqual(value.oneWayLatencyMilliseconds, 50 + 60 + 15, accuracy: 0.001)
    }

    func testReportSurfacesTheWorstSecondNotJustTheAverage() {
        let report = CallQualityReport(samples: [
            snapshot(loss: 0, roundTrip: 40, buffer: 30),
            snapshot(loss: 0, roundTrip: 40, buffer: 30),
            snapshot(loss: 0.25, roundTrip: 500, buffer: 300),
        ])
        XCTAssertLessThan(report.worstMOS, report.averageMOS)
        XCTAssertEqual(report.fractionBelowUsable, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(report.summaryLines().count, 4)
    }

    func testEmptyReportDoesNotDivideByZero() {
        let report = CallQualityReport(samples: [])
        XCTAssertEqual(report.averageMOS, 0)
        XCTAssertEqual(report.averageLossRate, 0)
        XCTAssertEqual(report.fractionBelowUsable, 0)
    }
}

final class CallCryptoTests: XCTestCase {
    func testBothEndsDeriveTheSameKey() throws {
        let caller = CallKeyExchange()
        let callee = CallKeyExchange()
        let room = "K7M2QD"
        let callerKey = try XCTUnwrap(caller.deriveKeyBase64(
            peerPublicKeyBase64: callee.publicKeyBase64, roomCode: room))
        let calleeKey = try XCTUnwrap(callee.deriveKeyBase64(
            peerPublicKeyBase64: caller.publicKeyBase64, roomCode: room))
        XCTAssertEqual(callerKey, calleeKey)
    }

    /// Binding the key to the room code means a captured public key cannot be
    /// replayed into a different call.
    func testDifferentRoomsDeriveDifferentKeys() throws {
        let caller = CallKeyExchange()
        let callee = CallKeyExchange()
        let first = try XCTUnwrap(caller.deriveKeyBase64(
            peerPublicKeyBase64: callee.publicKeyBase64, roomCode: "AAAAAA"))
        let second = try XCTUnwrap(caller.deriveKeyBase64(
            peerPublicKeyBase64: callee.publicKeyBase64, roomCode: "BBBBBB"))
        XCTAssertNotEqual(first, second)
    }

    func testGarbagePublicKeyIsRefused() {
        XCTAssertNil(CallKeyExchange().deriveKeyBase64(
            peerPublicKeyBase64: "not-base64!!", roomCode: "AAAAAA"))
    }

    func testSealedPacketRoundTripsBetweenDirections() throws {
        let key = CallCrypto.generateKeyBase64()
        let sender = try XCTUnwrap(CallCrypto(keyBase64: key, direction: .callerToCallee))
        let receiver = try XCTUnwrap(CallCrypto(keyBase64: key, direction: .calleeToCaller))
        let plaintext = Data("여보세요".utf8)
        let sealed = try XCTUnwrap(sender.seal(plaintext))
        XCTAssertNotEqual(sealed, plaintext)
        XCTAssertEqual(receiver.open(sealed), plaintext)
    }

    /// Each packet must get a fresh nonce; reuse under one key is a break.
    func testNoncesNeverRepeat() throws {
        let sender = try XCTUnwrap(CallCrypto(keyBase64: CallCrypto.generateKeyBase64(),
                                              direction: .callerToCallee))
        var nonces = Set<Data>()
        for _ in 0..<500 {
            let sealed = try XCTUnwrap(sender.seal(Data([0x01])))
            nonces.insert(sealed.prefix(CallSealedBox.nonceSize))
        }
        XCTAssertEqual(nonces.count, 500)
    }

    /// A relay that loops our own packets back must not be mistaken for the peer.
    func testOwnDirectionIsNotAccepted() throws {
        let key = CallCrypto.generateKeyBase64()
        let sender = try XCTUnwrap(CallCrypto(keyBase64: key, direction: .callerToCallee))
        let sameSide = try XCTUnwrap(CallCrypto(keyBase64: key, direction: .callerToCallee))
        let sealed = try XCTUnwrap(sender.seal(Data([0x02])))
        XCTAssertNil(sameSide.open(sealed))
    }

    func testTamperedPacketIsRejected() throws {
        let key = CallCrypto.generateKeyBase64()
        let sender = try XCTUnwrap(CallCrypto(keyBase64: key, direction: .callerToCallee))
        let receiver = try XCTUnwrap(CallCrypto(keyBase64: key, direction: .calleeToCaller))
        var sealed = try XCTUnwrap(sender.seal(Data(repeating: 7, count: 40)))
        sealed[sealed.count - 3] ^= 0xFF
        XCTAssertNil(receiver.open(sealed))
    }

    func testShortKeyIsRefused() {
        XCTAssertNil(CallCrypto(keyBase64: Data([1, 2, 3]).base64EncodedString(),
                                direction: .callerToCallee))
    }
}
