import Foundation

/// Finds stretches of a chunk where someone is clearly talking but the
/// transcript has nothing.
///
/// Whisper told the meeting is Korean doesn't translate a sentence said in
/// English — it drops it. Measured on a Korean meeting with two English lines
/// in the middle: `language=ko` returned the Korean around them and nothing
/// for nine seconds of clear English. Re-sending just that stretch with no
/// language hint brings it back verbatim, so the words are never lost while
/// the Korean keeps the hint that makes it accurate.
enum SpeechGaps {
    /// Transcript timestamps are coarse (whole seconds are common), so a
    /// segment is taken to cover a little either side of what it claims.
    static let coverageSlack: TimeInterval = 0.75
    /// Pauses between words inside one stretch of speech.
    static let maxHoleWindows = 3
    /// Less than this much uncovered speech is a breath or a cough.
    static let minimumSpeech: TimeInterval = 1.5

    /// Chunk-time ranges (lead-in excluded) of uncovered speech.
    static func regions(windowRMS: [Float], windowSeconds: TimeInterval,
                        covered: [ClosedRange<TimeInterval>]) -> [ClosedRange<TimeInterval>] {
        guard !windowRMS.isEmpty else { return [] }
        // Louder than the room's own quiet — the 5th percentile, which even a
        // wall-to-wall conversation spends between words — but never above
        // ordinary speech level, or dense talk would raise the bar over itself.
        let quiet = windowRMS.sorted()[windowRMS.count / 20]
        let threshold = max(0.008, min(0.05, quiet * 3))
        func isCovered(_ index: Int) -> Bool {
            let center = (Double(index) + 0.5) * windowSeconds
            return covered.contains {
                ($0.lowerBound - coverageSlack)...($0.upperBound + coverageSlack) ~= center
            }
        }

        var result: [ClosedRange<TimeInterval>] = []
        var start: Int?
        var last = 0
        var speech = 0
        func close() {
            if let first = start, Double(speech) * windowSeconds >= minimumSpeech {
                result.append(Double(first) * windowSeconds...Double(last + 1) * windowSeconds)
            }
            start = nil
            speech = 0
        }
        for index in windowRMS.indices {
            if isCovered(index) {
                close()
            } else if windowRMS[index] > threshold {
                if start == nil { start = index }
                last = index
                speech += 1
            } else if start != nil, index - last > maxHoleWindows {
                close()
            }
        }
        close()
        return result
    }

    /// Phrases whisper produces from silence or noise, not from speech.
    static let noisePhrases: Set<String> = [
        "thank you", "thank you.", "thanks for watching!", "thank you for watching.",
        "you", "bye.", "시청해주셔서 감사합니다.", "감사합니다.", "mbc 뉴스 이덕영입니다.",
    ]
}
