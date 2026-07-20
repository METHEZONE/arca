#if os(iOS)
import ActivityKit
import Foundation

/// ARCA's Live Activity — the Dynamic Island is where ARCA lives on iPhone.
/// One activity, two modes: an ambient "companion" presence that's almost
/// always there, and a "recording" mode while a session is live.
public struct RecordingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// "companion" (ambient) or "recording" (live session).
        public var mode: String
        public var startedAt: Date
        public var isPaused: Bool
        /// Rolling count of finalized live-transcript segments, for a subtle
        /// "it's hearing you" signal in the expanded island.
        public var segmentCount: Int
        /// A transient life sign in companion mode ("Reading your
        /// screenshot…", "3 actions ready") — nil shows the resting line.
        public var detail: String?

        public var isRecording: Bool { mode == "recording" }
        /// The spirit perks up while recording or actively working on something.
        public var isLively: Bool { (isRecording && !isPaused) || detail != nil }

        public init(mode: String = "recording", startedAt: Date,
                    isPaused: Bool = false, segmentCount: Int = 0,
                    detail: String? = nil) {
            self.mode = mode
            self.startedAt = startedAt
            self.isPaused = isPaused
            self.segmentCount = segmentCount
            self.detail = detail
        }
    }

    public var title: String

    public init(title: String) {
        self.title = title
    }
}
#endif
