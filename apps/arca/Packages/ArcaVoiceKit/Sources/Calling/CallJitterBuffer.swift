import Foundation

/// What the playout tick got back from the buffer.
public enum JitterBufferOutput: Sendable, Equatable {
    /// A frame is ready to decode and play.
    case frame(sequence: UInt32, payload: Data)
    /// Nothing playable: the buffer is still filling up before it starts.
    case prebuffering
    /// The expected frame never arrived. The caller should conceal (fade the
    /// previous frame) rather than insert silence, which clicks.
    case conceal(sequence: UInt32)
}

/// Adaptive playout buffer for incoming audio frames.
///
/// This is the single most important piece of a call's perceived quality. A
/// fixed 20ms buffer sounds perfect on Wi-Fi and shreds on LTE; a fixed 200ms
/// buffer survives anything but makes people talk over each other. So the depth
/// tracks measured network jitter and moves with it.
///
/// Pure logic on purpose — no audio, no sockets — so the behaviour that decides
/// whether a call sounds good is unit-testable without a device.
public final class CallJitterBuffer: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Never buffer less than this, even on a perfect network. Two frames of
        /// slack absorbs the normal scheduling wobble of the audio render thread.
        public var minimumFrames: Int = 2
        /// Ceiling on depth. Past ~200ms of buffer, conversation turn-taking
        /// breaks down and people start interrupting each other; dropping audio
        /// is the better trade.
        public var maximumFrames: Int = 20
        /// Multiplier on the jitter estimate. 3x covers ~99% of arrivals for a
        /// roughly normal delay distribution.
        public var jitterSafetyFactor: Double = 3.0
        /// How fast the depth is allowed to shrink once the network calms down.
        /// Slow, because shrinking too eagerly causes repeated underruns.
        public var shrinkRatePerSecond: Double = 0.5

        public init() {}
    }

    private struct Entry {
        let payload: Data
        let arrivedAtMicros: UInt64
    }

    private let config: Configuration
    private let lock = NSLock()

    private var entries: [UInt32: Entry] = [:]
    /// Next sequence we intend to hand to the decoder.
    private var playoutCursor: UInt32?
    private var isPrebuffering = true
    private var targetFrames: Double

    // Jitter estimation (RFC 3550 style, in microseconds).
    private var lastTransitMicros: Int64?
    private var jitterMicros: Double = 0
    private var lastShrinkAtMicros: UInt64 = 0

    // Counters for the quality HUD.
    private var receivedCount: UInt64 = 0
    private var duplicateCount: UInt64 = 0
    private var lateCount: UInt64 = 0
    private var concealedCount: UInt64 = 0
    private var underrunCount: UInt64 = 0
    private var highestSequenceSeen: UInt32 = 0

    public init(configuration: Configuration = Configuration()) {
        self.config = configuration
        self.targetFrames = Double(configuration.minimumFrames)
    }

    /// Feeds one frame in. Safe to call with duplicates — redundancy sends every
    /// frame twice on purpose, and the second copy is free insurance.
    public func insert(sequence: UInt32, payload: Data,
                       sentAtMicros: UInt64, arrivedAtMicros: UInt64) {
        lock.lock()
        defer { lock.unlock() }

        highestSequenceSeen = max(highestSequenceSeen, sequence)

        // Already played past it — arrived too late to be useful.
        if let cursor = playoutCursor, sequence < cursor {
            lateCount += 1
            return
        }
        if entries[sequence] != nil {
            duplicateCount += 1
            return
        }

        entries[sequence] = Entry(payload: payload, arrivedAtMicros: arrivedAtMicros)
        receivedCount += 1
        updateJitter(sentAtMicros: sentAtMicros, arrivedAtMicros: arrivedAtMicros)
        adaptTarget(now: arrivedAtMicros)
    }

    /// Called once per frame period by the audio render side.
    public func pop() -> JitterBufferOutput {
        lock.lock()
        defer { lock.unlock() }

        if isPrebuffering {
            guard Double(entries.count) >= targetFrames, let lowest = entries.keys.min() else {
                return .prebuffering
            }
            isPrebuffering = false
            playoutCursor = lowest
        }

        guard let cursor = playoutCursor else { return .prebuffering }

        if let entry = entries.removeValue(forKey: cursor) {
            playoutCursor = cursor &+ 1
            return .frame(sequence: cursor, payload: entry.payload)
        }

        // The frame we wanted is missing. If anything newer is waiting, the frame
        // is genuinely lost: conceal it and move on. If the buffer is completely
        // empty we have outrun the network, so go back to prebuffering instead of
        // concealing forever.
        if entries.isEmpty {
            underrunCount += 1
            isPrebuffering = true
            playoutCursor = nil
            // An underrun means the buffer was too shallow. React immediately —
            // this is the one case where growing fast is always right.
            targetFrames = min(Double(config.maximumFrames), targetFrames + 2)
            return .prebuffering
        }

        concealedCount += 1
        playoutCursor = cursor &+ 1
        return .conceal(sequence: cursor)
    }

    /// Snapshot for the quality HUD.
    public func statistics() -> Statistics {
        lock.lock()
        defer { lock.unlock() }
        return Statistics(
            bufferedFrames: entries.count,
            targetFrames: targetFrames,
            jitterMilliseconds: jitterMicros / 1_000,
            received: receivedCount,
            duplicates: duplicateCount,
            late: lateCount,
            concealed: concealedCount,
            underruns: underrunCount,
            highestSequence: highestSequenceSeen)
    }

    public struct Statistics: Sendable {
        public let bufferedFrames: Int
        public let targetFrames: Double
        public let jitterMilliseconds: Double
        public let received: UInt64
        public let duplicates: UInt64
        public let late: UInt64
        public let concealed: UInt64
        public let underruns: UInt64
        public let highestSequence: UInt32

        /// Share of frames that never made it in time. This is the number that
        /// correlates with "지지직" — anything above ~2% is audible.
        public var lossRate: Double {
            let expected = received + concealed
            guard expected > 0 else { return 0 }
            return Double(concealed) / Double(expected)
        }

        public var bufferMilliseconds: Double {
            Double(bufferedFrames) * CallWire.frameDuration * 1_000
        }
    }

    // MARK: - Private

    /// RFC 3550 interarrival jitter, kept in microseconds.
    private func updateJitter(sentAtMicros: UInt64, arrivedAtMicros: UInt64) {
        // Clocks are not synced, so transit is an offset with an unknown constant.
        // The constant cancels in the difference, which is all we use.
        let transit = Int64(bitPattern: arrivedAtMicros) - Int64(bitPattern: sentAtMicros)
        defer { lastTransitMicros = transit }
        guard let previous = lastTransitMicros else { return }
        let delta = abs(Double(transit - previous))
        jitterMicros += (delta - jitterMicros) / 16.0
    }

    private func adaptTarget(now: UInt64) {
        let needed = (jitterMicros * config.jitterSafetyFactor) / 1_000_000 / CallWire.frameDuration
        let wanted = max(Double(config.minimumFrames),
                         min(Double(config.maximumFrames), needed + Double(config.minimumFrames)))
        if wanted > targetFrames {
            // Grow immediately: being late is worse than being deep.
            targetFrames = wanted
            lastShrinkAtMicros = now
            return
        }
        // Shrink on a leash so a brief calm patch does not set us up for the next
        // burst of jitter.
        let elapsed = Double(now &- lastShrinkAtMicros) / 1_000_000
        guard elapsed > 0 else { return }
        let allowedShrink = elapsed * config.shrinkRatePerSecond
        targetFrames = max(wanted, targetFrames - allowedShrink)
        lastShrinkAtMicros = now
    }
}
