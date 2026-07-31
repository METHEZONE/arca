import Foundation
import Network
import CryptoKit

/// Carries media datagrams between the two ends via a relay.
///
/// Why a relay instead of true peer-to-peer: both ends are phones behind carrier
/// NAT, where hole punching fails often enough that we would need full ICE plus a
/// TURN server as fallback — and the TURN fallback is a relay anyway. So we skip
/// straight to the relay and get one predictable path instead of two
/// unpredictable ones. With the box in Seoul the extra hop costs ~10-20ms, which
/// the quality HUD will show plainly.
///
/// Relay envelope (outside the encryption, because the relay must route it):
///   0        type (UInt8) — 1 register/keepalive, 2 media
///   1..16    room token (16 bytes, SHA256 prefix of the room code)
///   17       side (UInt8) — 0 caller, 1 callee
///   18...    sealed media payload
public final class CallMediaTransport: @unchecked Sendable {
    public enum EnvelopeType: UInt8 {
        case register = 1
        case media = 2
    }

    private static let tokenSize = 16
    private static let envelopeHeaderSize = 1 + 16 + 1

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.thezone.arca.call.transport")
    private let roomToken: Data
    private let side: UInt8
    private let crypto: CallCrypto

    private var keepaliveTimer: DispatchSourceTimer?
    private var onPacket: (@Sendable (CallPacket, Int, UInt64) -> Void)?
    private var onStateChange: (@Sendable (Bool) -> Void)?
    private var isReady = false

    public init(relayHost: String, relayPort: UInt16,
                roomCode: String, isCaller: Bool, keyBase64: String) throws {
        guard let crypto = CallCrypto(keyBase64: keyBase64,
                                      direction: isCaller ? .callerToCallee : .calleeToCaller) else {
            throw CallError.transportFailed("bad call key")
        }
        self.crypto = crypto
        self.side = isCaller ? 0 : 1
        self.roomToken = Data(SHA256.hash(data: Data(roomCode.utf8)).prefix(Self.tokenSize))

        guard let port = NWEndpoint.Port(rawValue: relayPort) else {
            throw CallError.transportFailed("bad relay port")
        }
        let parameters = NWParameters.udp
        // Voice is the whole point: ask the OS to treat this socket accordingly so
        // it is queued ahead of background traffic on a congested radio.
        parameters.serviceClass = .responsiveData
        self.connection = NWConnection(host: NWEndpoint.Host(relayHost),
                                       port: port,
                                       using: parameters)
    }

    public func start(onPacket: @escaping @Sendable (CallPacket, Int, UInt64) -> Void,
                      onReadyChange: @escaping @Sendable (Bool) -> Void) {
        self.onPacket = onPacket
        self.onStateChange = onReadyChange

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                CallTrace.log("transport: ready")
                self.isReady = true
                onReadyChange(true)
                self.sendRegister()
                self.startKeepalive()
            case .failed(let error):
                CallTrace.log("transport: failed — \(error)")
                self.isReady = false
                onReadyChange(false)
            case .cancelled:
                self.isReady = false
                onReadyChange(false)
            default:
                break
            }
        }
        receiveLoop()
        connection.start(queue: queue)
    }

    public func stop() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        connection.cancel()
    }

    /// Seals and sends one media packet. Returns the wire byte count so the
    /// quality monitor can track real bandwidth rather than payload size.
    @discardableResult
    public func send(_ packet: CallPacket) -> Int {
        guard isReady else { return 0 }
        let plaintext = CallPacketCoder.encode(packet)
        guard let sealed = crypto.seal(plaintext) else { return 0 }
        var datagram = Data(capacity: Self.envelopeHeaderSize + sealed.count)
        datagram.append(EnvelopeType.media.rawValue)
        datagram.append(roomToken)
        datagram.append(side)
        datagram.append(sealed)
        connection.send(content: datagram, completion: .idempotent)
        return datagram.count
    }

    // MARK: - Private

    private func sendRegister() {
        var datagram = Data(capacity: Self.envelopeHeaderSize)
        datagram.append(EnvelopeType.register.rawValue)
        datagram.append(roomToken)
        datagram.append(side)
        connection.send(content: datagram, completion: .idempotent)
    }

    /// Carrier NAT drops idle UDP bindings in well under a minute, and a call has
    /// natural silence in it. Keep the pinhole warm.
    private func startKeepalive() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.sendRegister() }
        timer.resume()
        keepaliveTimer = timer
    }

    private func receiveLoop() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, data.count > Self.envelopeHeaderSize {
                self.handle(datagram: data)
            }
            if let error {
                CallTrace.log("transport: receive error — \(error)")
                return
            }
            self.receiveLoop()
        }
    }

    private func handle(datagram: Data) {
        let bytes = [UInt8](datagram)
        guard bytes[0] == EnvelopeType.media.rawValue else { return }
        let token = datagram.subdata(in: 1..<(1 + Self.tokenSize))
        guard token == roomToken else { return }
        // The relay should never echo our own side back, but check anyway.
        guard bytes[1 + Self.tokenSize] != side else { return }

        let sealed = datagram.subdata(in: Self.envelopeHeaderSize..<datagram.count)
        guard let plaintext = crypto.open(sealed),
              let packet = CallPacketCoder.decode(plaintext) else { return }
        onPacket?(packet, datagram.count, CallClock.nowMicros())
    }
}
