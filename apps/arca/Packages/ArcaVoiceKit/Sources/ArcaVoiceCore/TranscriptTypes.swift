import Foundation

/// A streaming transcription result. `isVolatile` segments may still change;
/// finalized segments replace them. The UI animates volatile → finalized.
public struct LiveSegment: Sendable, Identifiable {
    public let id: UUID
    public let channel: CaptureChannel
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var isVolatile: Bool

    public init(id: UUID = UUID(), channel: CaptureChannel, text: String,
                start: TimeInterval, end: TimeInterval, isVolatile: Bool) {
        self.id = id
        self.channel = channel
        self.text = text
        self.start = start
        self.end = end
        self.isVolatile = isVolatile
    }
}

/// A finished, high-quality transcript for one audio file (one channel).
public struct Transcript: Sendable {
    public struct Segment: Sendable {
        public var text: String
        public var start: TimeInterval
        public var end: TimeInterval
        public var confidence: Double?
        /// Diarization label local to this transcript (e.g. "S1"), if the engine provided one.
        public var speakerLabel: String?

        public init(text: String, start: TimeInterval, end: TimeInterval,
                    confidence: Double? = nil, speakerLabel: String? = nil) {
            self.text = text
            self.start = start
            self.end = end
            self.confidence = confidence
            self.speakerLabel = speakerLabel
        }
    }

    public var channel: CaptureChannel
    public var segments: [Segment]
    public var languageCode: String?

    public init(channel: CaptureChannel, segments: [Segment], languageCode: String? = nil) {
        self.channel = channel
        self.segments = segments
        self.languageCode = languageCode
    }
}

/// Context passed to the final-pass engine to boost accuracy.
public struct TranscriptHints: Sendable {
    /// Vocabulary likely to appear: attendee names, product terms, company jargon.
    public var vocabulary: [String]
    public var languageCodes: [String]

    public init(vocabulary: [String] = [], languageCodes: [String] = ["ko", "en"]) {
        self.vocabulary = vocabulary
        self.languageCodes = languageCodes
    }
}
