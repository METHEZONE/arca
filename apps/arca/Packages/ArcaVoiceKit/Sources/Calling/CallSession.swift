import Foundation
import Observation

/// Where a call is in its life.
public enum CallState: Sendable, Equatable {
    case idle
    /// Signaling connected, waiting for the other side to show up.
    case waitingForPeer
    /// Keys agreed, media socket coming up.
    case connecting
    case active
    case ended(reason: String)

    public var isLive: Bool {
        switch self {
        case .waitingForPeer, .connecting, .active: true
        case .idle, .ended: false
        }
    }
}

/// A finished call, ready for the transcribe pipeline.
public struct CallOutcome: Sendable {
    public let roomCode: String
    public let startedAt: Date
    public let duration: TimeInterval
    public let recording: CallRecorder.Result?
    public let quality: CallQualityReport
}

/// UI-facing controller for an ARCA↔ARCA call.
///
/// Everything observable lives on the main actor; everything on the audio and
/// network hot path lives in `CallMediaPipeline`. The two meet only at the
/// once-a-second quality snapshot.
@MainActor
@Observable
public final class CallSession {
    public private(set) var state: CallState = .idle
    public private(set) var quality = CallQualitySnapshot()
    public private(set) var roomCode: String = ""
    public private(set) var side: CallSide = .caller
    public private(set) var isTransportReady = false
    public private(set) var startedAt: Date?
    public private(set) var lastOutcome: CallOutcome?

    /// Wall-clock call length, for the UI timer.
    public var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    private let configuration: CallConfiguration
    private let recordingRoot: URL
    private var signaling: CallSignalingClient?
    private var pipeline: CallMediaPipeline?
    private var keyExchange: CallKeyExchange?
    private var hasStartedMedia = false

    public init(configuration: CallConfiguration, recordingRoot: URL) {
        self.configuration = configuration
        self.recordingRoot = recordingRoot
    }

    /// Human-typeable room code. Six characters from an alphabet with no 0/O or
    /// 1/I, because these get read aloud over another phone.
    public static func generateRoomCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).map { _ in alphabet.randomElement() ?? "A" })
    }

    public func start(roomCode: String, as side: CallSide) async {
        guard !state.isLive else { return }
        let normalized = roomCode.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            state = .ended(reason: "방 코드가 없습니다")
            return
        }

        guard await CallAudioEngine.requestMicrophonePermission() else {
            state = .ended(reason: "마이크 권한이 필요합니다")
            return
        }

        self.roomCode = normalized
        self.side = side
        self.hasStartedMedia = false
        self.quality = CallQualitySnapshot()
        self.state = .waitingForPeer

        let exchange = CallKeyExchange()
        self.keyExchange = exchange

        let client = CallSignalingClient(signalingURL: configuration.signalingURL)
        self.signaling = client
        client.connect(room: normalized, side: side,
                       publicKeyBase64: exchange.publicKeyBase64) { [weak self] signal in
            Task { @MainActor [weak self] in
                self?.handle(signal)
            }
        }
    }

    public func hangUp(reason: String = "종료") {
        signaling?.leave()
        signaling = nil
        finishMedia(reason: reason)
    }

    // MARK: - Private

    private func handle(_ signal: CallSignal) {
        switch signal {
        case .joined:
            CallTrace.log("session: joined \(roomCode)")
        case .peerReady(let publicKey):
            beginMedia(peerPublicKey: publicKey)
        case .peerLeft:
            hangUp(reason: "상대방이 종료했습니다")
        case .roomFull:
            state = .ended(reason: "이미 통화 중인 방입니다")
        case .failed(let message):
            state = .ended(reason: message)
        }
    }

    private func beginMedia(peerPublicKey: String) {
        // Both sides announce, so this can fire twice. Only the first one counts.
        guard !hasStartedMedia, let exchange = keyExchange else { return }
        guard let key = exchange.deriveKeyBase64(peerPublicKeyBase64: peerPublicKey,
                                                 roomCode: roomCode) else {
            state = .ended(reason: "키 교환 실패")
            return
        }
        hasStartedMedia = true
        state = .connecting

        let directory = recordingRoot
            .appendingPathComponent("calls", isDirectory: true)
            .appendingPathComponent("\(Self.timestamp())-\(roomCode)", isDirectory: true)

        do {
            let pipeline = try CallMediaPipeline(configuration: configuration,
                                                 recordingDirectory: directory)
            self.pipeline = pipeline
            try pipeline.start(roomCode: roomCode,
                               isCaller: side.isCaller,
                               keyBase64: key,
                               onQuality: { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    self?.quality = snapshot
                }
            }, onTransportReady: { [weak self] ready in
                Task { @MainActor [weak self] in
                    self?.isTransportReady = ready
                    if ready, self?.state == .connecting {
                        self?.state = .active
                        self?.startedAt = Date()
                    }
                }
            })
        } catch {
            CallTrace.log("session: media start failed — \(error)")
            state = .ended(reason: "통화 시작 실패: \(error)")
        }
    }

    private func finishMedia(reason: String) {
        guard let pipeline else {
            if state.isLive { state = .ended(reason: reason) }
            return
        }
        let report = pipeline.qualityReport
        let recording = pipeline.stop()
        self.pipeline = nil
        lastOutcome = CallOutcome(roomCode: roomCode,
                                  startedAt: startedAt ?? Date(),
                                  duration: elapsed,
                                  recording: recording,
                                  quality: report)
        startedAt = nil
        state = .ended(reason: reason)
        for line in report.summaryLines() { CallTrace.log("quality: \(line)") }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
