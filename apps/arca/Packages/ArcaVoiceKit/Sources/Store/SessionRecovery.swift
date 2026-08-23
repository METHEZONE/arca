import Foundation

/// Pure decisions about which stored sessions need rescuing.
///
/// Split out of the app layer so the rules that decide whether a recording is
/// stranded are testable without SwiftData, a Keychain, or a running app — every
/// one of them exists because a session went permanently invisible in the field.
public enum SessionRecovery {
    /// Whether the high-quality pass should be run (or re-run) for a session.
    ///
    /// The old rule matched only on the `processingError` text, which meant a
    /// session killed *during* the pass was unreachable forever: the app died
    /// before it could write down why, so the row sat in `.processing` with a nil
    /// error and no retry ever looked at it again. State, not the error string,
    /// is the reliable signal — the audio is still on disk either way.
    public static func needsFinalPass(state: SessionState,
                                      processingError: String?,
                                      hasAudio: Bool) -> Bool {
        guard hasAudio else { return false }
        if state == .processing || state == .failed { return true }
        guard let processingError else { return false }
        return processingError.contains("High-quality pass failed")
            || processingError.contains("고품질 패스")
    }

    /// A `.recording` row is only truthful while that recording is actually
    /// running in this process. Anything else is the residue of a kill and has to
    /// be moved into the processing queue, or it stays invisible forever.
    public static func isStrandedRecording(state: SessionState,
                                           directoryName: String,
                                           activeDirectoryName: String?) -> Bool {
        state == .recording && directoryName != activeDirectoryName
    }

    /// How much of a recording the live transcript has to reach before it can
    /// stand in for a failed final pass.
    public static let liveCoverageFloor = 0.6

    /// Whether the live on-device transcript already in the store covers enough
    /// of the recording to be used instead of decoding the file and running the
    /// same on-device model over it a second time.
    public static func liveTranscriptCovers(duration: TimeInterval,
                                            lastSegmentEnd: TimeInterval,
                                            hasText: Bool) -> Bool {
        guard hasText else { return false }
        // Unknown duration (a recovered session whose container has no moov box)
        // can't be measured against, so any text counts.
        guard duration > 1 else { return true }
        return lastSegmentEnd >= duration * liveCoverageFloor
    }

    /// Session directories sitting on disk with no row pointing at them —
    /// what a kill before the first save leaves behind.
    public static func orphanDirectories(onDisk: [String],
                                         known: some Sequence<String>) -> [String] {
        let index = Set(known)
        return onDisk.filter { !index.contains($0) }.sorted()
    }
}
