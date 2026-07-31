import Foundation

/// Messages on the signaling socket. Deliberately tiny — this channel only has to
/// get two devices to agree on a room and a key, then get out of the way.
public enum CallSignal: Sendable {
    case joined(side: CallSide)
    case peerReady(publicKeyBase64: String)
    case peerLeft
    case roomFull
    case failed(String)
}

public enum CallSide: String, Codable, Sendable {
    case caller
    case callee

    public var isCaller: Bool { self == .caller }
}

/// WebSocket client for call setup.
///
/// Runs over WSS, so the room code and public keys are never in the clear. It
/// never sees the media key (see `CallKeyExchange`) and never touches audio.
public final class CallSignalingClient: @unchecked Sendable {
    private struct OutboundMessage: Encodable {
        let type: String
        var room: String?
        var side: String?
        var publicKey: String?
    }

    private struct InboundMessage: Decodable {
        let type: String
        var side: String?
        var publicKey: String?
        var message: String?
    }

    private let url: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private let lock = NSLock()
    private var onSignal: (@Sendable (CallSignal) -> Void)?
    private var isClosed = false

    public init(signalingURL: URL) {
        self.url = signalingURL
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: configuration)
    }

    public func connect(room: String, side: CallSide, publicKeyBase64: String,
                        onSignal: @escaping @Sendable (CallSignal) -> Void) {
        lock.lock()
        self.onSignal = onSignal
        lock.unlock()

        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveLoop()

        send(OutboundMessage(type: "join", room: room, side: side.rawValue,
                             publicKey: publicKeyBase64))
        CallTrace.log("signaling: joining \(room) as \(side.rawValue)")
    }

    /// Re-announces our public key. The callee may join after the caller, so
    /// whoever is second triggers an exchange in both directions.
    public func announce(publicKeyBase64: String) {
        send(OutboundMessage(type: "announce", room: nil, side: nil,
                             publicKey: publicKeyBase64))
    }

    public func leave() {
        lock.lock()
        isClosed = true
        lock.unlock()
        send(OutboundMessage(type: "leave", room: nil, side: nil, publicKey: nil))
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        CallTrace.log("signaling: left")
    }

    // MARK: - Private

    private func send(_ message: OutboundMessage) {
        guard let task, let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { error in
            if let error { CallTrace.log("signaling: send failed — \(error)") }
        }
    }

    private func emit(_ signal: CallSignal) {
        lock.lock()
        let handler = onSignal
        lock.unlock()
        handler?(signal)
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.lock.lock()
                let closed = self.isClosed
                self.lock.unlock()
                if !closed {
                    CallTrace.log("signaling: receive failed — \(error)")
                    self.emit(.failed(error.localizedDescription))
                }
            case .success(let message):
                if case .string(let text) = message {
                    self.handle(text)
                } else if case .data(let data) = message,
                          let text = String(data: data, encoding: .utf8) {
                    self.handle(text)
                }
                self.receiveLoop()
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(InboundMessage.self, from: data) else {
            return
        }
        switch message.type {
        case "joined":
            let side = CallSide(rawValue: message.side ?? "") ?? .caller
            emit(.joined(side: side))
        case "peer-ready":
            guard let key = message.publicKey else { return }
            emit(.peerReady(publicKeyBase64: key))
        case "peer-left":
            emit(.peerLeft)
        case "room-full":
            emit(.roomFull)
        case "error":
            emit(.failed(message.message ?? "signaling error"))
        default:
            break
        }
    }
}
