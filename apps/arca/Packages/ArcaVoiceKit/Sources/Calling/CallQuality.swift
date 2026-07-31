import Foundation

/// Everything the in-call HUD shows, and everything the post-call log keeps.
///
/// The point of this type is to make "에이닷보다 나은가?" an answerable question
/// instead of a feeling. Loss, jitter and round-trip are the three numbers that
/// decide whether a call sounds broken.
public struct CallQualitySnapshot: Sendable, Codable {
    public var roundTripMilliseconds: Double = 0
    public var jitterMilliseconds: Double = 0
    public var lossRate: Double = 0
    public var jitterBufferMilliseconds: Double = 0
    public var inboundKilobitsPerSecond: Double = 0
    public var outboundKilobitsPerSecond: Double = 0
    public var concealedFrames: UInt64 = 0
    public var underruns: UInt64 = 0
    /// Fraction of received frames that arrived twice. High is fine and means the
    /// redundancy is doing its job cheaply; it is not a problem signal.
    public var duplicateRate: Double = 0

    public init() {}

    /// One-way mouth-to-ear latency, approximated as half the round trip plus
    /// the buffer we are deliberately holding plus the codec's own delay.
    public var oneWayLatencyMilliseconds: Double {
        roundTripMilliseconds / 2 + jitterBufferMilliseconds + Self.codecDelayMilliseconds
    }

    /// AAC-ELD's algorithmic delay. Included so the latency figure is honest
    /// rather than flattering.
    static let codecDelayMilliseconds: Double = 15

    /// Simplified ITU-T G.107 E-model, reduced to the two impairments that
    /// actually move on a mobile network: delay and packet loss.
    ///
    /// Returned on the familiar 1.0-4.5 MOS scale. Rough reading:
    ///   4.0+  better than a normal cellular call
    ///   3.6+  fine, nobody complains
    ///   3.0+  usable but people notice
    ///   <3.0  this is the 지지직 zone
    public var estimatedMOS: Double {
        let delay = oneWayLatencyMilliseconds
        // Base rating for a wideband codec on a clean path.
        var r = 93.2

        // Delay impairment. Under ~150ms one-way, humans barely notice; past that
        // it climbs steeply.
        let delayPenalty: Double
        if delay < 150 {
            delayPenalty = 0.024 * delay
        } else {
            delayPenalty = 0.024 * delay + 0.11 * (delay - 150)
        }
        r -= delayPenalty

        // Loss impairment. The 15 reflects that a codec with concealment degrades
        // gracefully rather than falling off a cliff. The 3.0 was calibrated
        // against the E-model's Ie-eff for wideband speech: 5% loss has to cost
        // roughly 22 R points (~0.8 MOS), because 5% loss on a real call is
        // plainly audible and a gentler curve would let the HUD call a broken
        // call "good".
        let lossPercent = lossRate * 100
        r -= 30 * log(1 + 15 * lossPercent / 100) / log(10) * 3.0

        r = max(0, min(100, r))

        // R → MOS conversion from G.107.
        if r < 0 { return 1.0 }
        if r > 100 { return 4.5 }
        let mos = 1 + 0.035 * r + r * (r - 60) * (100 - r) * 7e-6
        return max(1.0, min(4.5, mos))
    }

    public var verdict: String {
        switch estimatedMOS {
        case 4.0...: "아주 좋음 (일반 통화보다 나음)"
        case 3.6..<4.0: "좋음"
        case 3.0..<3.6: "보통 (약간 거슬림)"
        case 2.5..<3.0: "나쁨 (끊김 체감)"
        default: "매우 나쁨"
        }
    }
}

/// Accumulates raw counters and turns them into snapshots once a second.
///
/// Round-trip is measured without a separate ping: every outgoing packet carries
/// the highest sequence we have received, so when a packet comes back echoing one
/// of our own sequences we know how long the loop took.
public final class CallQualityMonitor: @unchecked Sendable {
    private let lock = NSLock()

    private var outboundSentAt: [UInt32: UInt64] = [:]
    private var roundTripEstimateMicros: Double = 0
    private var hasRoundTrip = false

    private var inboundBytesWindow: Int = 0
    private var outboundBytesWindow: Int = 0
    private var windowStartedAtMicros: UInt64 = CallClock.nowMicros()

    private var latestSnapshot = CallQualitySnapshot()
    private var history: [CallQualitySnapshot] = []

    public init() {}

    /// Records that we sent a packet whose first frame has this sequence.
    public func didSend(sequence: UInt32, byteCount: Int, atMicros: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        outboundBytesWindow += byteCount
        outboundSentAt[sequence] = atMicros
        // Bound the map: at 50 packets/sec this keeps ~10 seconds of history.
        if outboundSentAt.count > 600 {
            let cutoff = atMicros &- 10_000_000
            outboundSentAt = outboundSentAt.filter { $0.value > cutoff }
        }
    }

    /// Records an inbound packet. `echoedSequence` is the newest sequence of ours
    /// the far end had seen when it sent this.
    public func didReceive(byteCount: Int, echoedSequence: UInt32, atMicros: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        inboundBytesWindow += byteCount
        guard let sentAt = outboundSentAt.removeValue(forKey: echoedSequence) else { return }
        let sample = Double(atMicros &- sentAt)
        // Ignore absurd samples (app was suspended, clock weirdness).
        guard sample > 0, sample < 5_000_000 else { return }
        if hasRoundTrip {
            roundTripEstimateMicros += (sample - roundTripEstimateMicros) / 8.0
        } else {
            roundTripEstimateMicros = sample
            hasRoundTrip = true
        }
    }

    /// Folds in the jitter buffer's view and closes the one-second window.
    public func tick(bufferStats: CallJitterBuffer.Statistics) -> CallQualitySnapshot {
        lock.lock()
        defer { lock.unlock() }

        let now = CallClock.nowMicros()
        let elapsedSeconds = max(0.001, Double(now &- windowStartedAtMicros) / 1_000_000)

        var snapshot = CallQualitySnapshot()
        snapshot.roundTripMilliseconds = roundTripEstimateMicros / 1_000
        snapshot.jitterMilliseconds = bufferStats.jitterMilliseconds
        snapshot.lossRate = bufferStats.lossRate
        snapshot.jitterBufferMilliseconds = bufferStats.bufferMilliseconds
        snapshot.inboundKilobitsPerSecond = Double(inboundBytesWindow) * 8 / 1_000 / elapsedSeconds
        snapshot.outboundKilobitsPerSecond = Double(outboundBytesWindow) * 8 / 1_000 / elapsedSeconds
        snapshot.concealedFrames = bufferStats.concealed
        snapshot.underruns = bufferStats.underruns
        let totalReceived = bufferStats.received + bufferStats.duplicates
        snapshot.duplicateRate = totalReceived > 0
            ? Double(bufferStats.duplicates) / Double(totalReceived) : 0

        inboundBytesWindow = 0
        outboundBytesWindow = 0
        windowStartedAtMicros = now
        latestSnapshot = snapshot
        history.append(snapshot)
        return snapshot
    }

    public var current: CallQualitySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return latestSnapshot
    }

    /// Per-second history, for the post-call report he can hold next to an 에이닷 call.
    public func report() -> CallQualityReport {
        lock.lock()
        defer { lock.unlock() }
        return CallQualityReport(samples: history)
    }
}

public struct CallQualityReport: Sendable, Codable {
    public let samples: [CallQualitySnapshot]

    public init(samples: [CallQualitySnapshot]) {
        self.samples = samples
    }

    public var averageMOS: Double {
        guard !samples.isEmpty else { return 0 }
        return samples.map(\.estimatedMOS).reduce(0, +) / Double(samples.count)
    }

    /// The worst second of the call. More useful than the average — one bad
    /// stretch is what people remember.
    public var worstMOS: Double {
        samples.map(\.estimatedMOS).min() ?? 0
    }

    public var averageLossRate: Double {
        guard !samples.isEmpty else { return 0 }
        return samples.map(\.lossRate).reduce(0, +) / Double(samples.count)
    }

    public var averageRoundTripMilliseconds: Double {
        guard !samples.isEmpty else { return 0 }
        return samples.map(\.roundTripMilliseconds).reduce(0, +) / Double(samples.count)
    }

    /// Share of the call that spent time below MOS 3.0 — the 지지직 zone.
    public var fractionBelowUsable: Double {
        guard !samples.isEmpty else { return 0 }
        let bad = samples.filter { $0.estimatedMOS < 3.0 }.count
        return Double(bad) / Double(samples.count)
    }

    public func summaryLines() -> [String] {
        [
            String(format: "평균 MOS %.2f / 최저 %.2f", averageMOS, worstMOS),
            String(format: "평균 손실률 %.2f%%", averageLossRate * 100),
            String(format: "평균 왕복 지연 %.0fms", averageRoundTripMilliseconds),
            String(format: "품질 불량 구간 %.0f%%", fractionBelowUsable * 100),
        ]
    }
}
