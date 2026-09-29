import Foundation
import ArcaVoiceCore

/// Hears which language is being spoken instead of assuming one.
///
/// The on-device recognizers need a locale up front, and the wrong one doesn't
/// fail — it produces fluent nonsense in the wrong language. So the first
/// stretch of audio goes to one recognizer per candidate language at once;
/// whichever is more confident keeps running for the rest of the recording and
/// the others are stopped. Until that call is made, finalized text is held
/// back (the first candidate's in-progress line still shows, so the screen
/// isn't blank), then the winner's is released in order.
public final class AutoLanguageTranscriber: LiveTranscriber, @unchecked Sendable {
    private let candidates: [Locale]
    private let make: @Sendable (Locale) -> any LiveTranscriber
    private let decided: @Sendable (Locale) -> Void
    /// Seconds of speech (by segment end time) to hear before deciding.
    private let window: TimeInterval

    public init(candidates: [Locale], window: TimeInterval = 20,
                make: @escaping @Sendable (Locale) -> any LiveTranscriber,
                decided: @escaping @Sendable (Locale) -> Void = { _ in }) {
        self.candidates = candidates
        self.window = window
        self.make = make
        self.decided = decided
    }

    public func transcribe(_ buffers: AsyncStream<CapturedBuffer>, channel: CaptureChannel, locale: Locale)
        -> AsyncThrowingStream<LiveSegment, Error>
    {
        guard candidates.count > 1 else {
            return make(candidates.first ?? locale).transcribe(buffers, channel: channel, locale: candidates.first ?? locale)
        }
        return AsyncThrowingStream { continuation in
            let state = Race(count: candidates.count)
            // One input stream per candidate, fed from the single capture stream.
            var inputs: [AsyncStream<CapturedBuffer>.Continuation] = []
            var tasks: [Task<Void, Never>] = []
            for (index, candidate) in candidates.enumerated() {
                let (stream, input) = AsyncStream<CapturedBuffer>.makeStream(bufferingPolicy: .bufferingNewest(128))
                inputs.append(input)
                let inner = make(candidate)
                tasks.append(Task {
                    do {
                        for try await segment in inner.transcribe(stream, channel: channel, locale: candidate) {
                            switch state.offer(segment, from: index, window: self.window) {
                            case .hold: break
                            case .show: continuation.yield(segment)
                            case .decided(let winner, let held):
                                self.decided(self.candidates[winner])
                                for segment in held { continuation.yield(segment) }
                                if winner != index { continue }
                                continuation.yield(segment)
                            case .drop: break
                            }
                        }
                    } catch {
                        // A candidate that can't run (model missing) just loses.
                        state.fail(index)
                    }
                    // A recording shorter than the window ends undecided: the last
                    // candidate to stop makes the call on what it heard so far.
                    let end = state.end(index)
                    if let winner = end.decided {
                        self.decided(self.candidates[winner])
                        for segment in end.flush { continuation.yield(segment) }
                    }
                    if end.finish { continuation.finish() }
                })
            }
            let feeds = inputs, runs = tasks
            let feeder = Task {
                for await buffer in buffers {
                    let live = state.liveIndices
                    for (i, input) in feeds.enumerated() where live.contains(i) { input.yield(buffer) }
                    for (i, input) in feeds.enumerated() where !live.contains(i) { input.finish() }
                }
                for input in feeds { input.finish() }
            }
            continuation.onTermination = { _ in
                feeder.cancel()
                runs.forEach { $0.cancel() }
                feeds.forEach { $0.finish() }
            }
        }
    }

    /// The shared scoreboard. Locked — each candidate reports from its own task.
    final class Race: @unchecked Sendable {
        enum Verdict { case hold, show, drop, decided(winner: Int, held: [LiveSegment]) }

        private let lock = NSLock()
        private var winner: Int?
        private var finals: [[LiveSegment]]
        private var failed: Set<Int> = []
        private var finished: Set<Int> = []

        init(count: Int) { finals = Array(repeating: [], count: count) }

        var liveIndices: Set<Int> {
            lock.withLock {
                if let winner { return [winner] }
                return Set(finals.indices).subtracting(failed)
            }
        }

        /// A candidate's stream ended. Decides if nobody has yet and every
        /// candidate is done; says whether the output should close.
        func end(_ index: Int) -> (decided: Int?, flush: [LiveSegment], finish: Bool) {
            lock.withLock {
                finished.insert(index)
                if let winner { return (nil, [], winner == index) }
                guard finished.count == finals.count else { return (nil, [], false) }
                let chosen = pick()
                winner = chosen
                return (chosen, finals[chosen], true)
            }
        }

        func fail(_ index: Int) {
            lock.withLock { failed.insert(index) }
        }

        func offer(_ segment: LiveSegment, from index: Int, window: TimeInterval) -> Verdict {
            lock.withLock {
                if let winner { return winner == index ? .show : .drop }
                if segment.isVolatile { return index == firstAlive ? .show : .hold }
                finals[index].append(segment)
                let heard = finals.map { $0.last?.end ?? 0 }.max() ?? 0
                guard heard >= window else { return .hold }
                let chosen = pick()
                winner = chosen
                // The segment that triggered the call is yielded separately by
                // its own candidate, so it isn't in `held` twice.
                var held = finals[chosen]
                if chosen == index { held.removeLast() }
                return .decided(winner: chosen, held: held)
            }
        }

        private var firstAlive: Int { finals.indices.first { !failed.contains($0) } ?? 0 }

        /// Most confident wins (length-weighted); a candidate that reports no
        /// confidence falls back to how much it recognized at all. Ties go to
        /// the first candidate — the user's own language.
        private func pick() -> Int {
            func score(_ i: Int) -> Double {
                let segments = finals[i]
                let scored = segments.compactMap { s in s.confidence.map { ($0, Double(s.text.count)) } }
                let weight = scored.reduce(0) { $0 + $1.1 }
                return weight > 0 ? scored.reduce(0) { $0 + $1.0 * $1.1 } / weight : 0
            }
            let alive = finals.indices.filter { !failed.contains($0) && !finals[$0].isEmpty }
            guard var best = alive.first else { return firstAlive }
            for i in alive where score(i) > score(best) + 0.05 { best = i }
            return best
        }
    }
}
