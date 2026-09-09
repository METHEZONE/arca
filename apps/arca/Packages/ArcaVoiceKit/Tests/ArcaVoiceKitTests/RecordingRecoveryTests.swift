import Testing
import Foundation
import ArcaVoiceKit

/// The rules that decide whether an interrupted recording ever gets finished.
/// Each case here is a way a session became permanently invisible in the field.
@Suite struct SessionRecoveryTests {
    @Test func retriesSessionStrandedInProcessingWithNoErrorText() {
        // The app was killed mid-pass, so it never got to write down why. The
        // old error-string match saw nothing here and the session sat forever.
        #expect(SessionRecovery.needsFinalPass(
            state: .processing, processingError: nil, hasAudio: true))
    }

    @Test func retriesSessionThatRecordedAnError() {
        #expect(SessionRecovery.needsFinalPass(
            state: .ready,
            processingError: "High-quality pass failed: the network went away",
            hasAudio: true))
        #expect(SessionRecovery.needsFinalPass(
            state: .ready, processingError: "고품질 패스 실패", hasAudio: true))
    }

    @Test func retriesFailedSessions() {
        #expect(SessionRecovery.needsFinalPass(
            state: .failed, processingError: nil, hasAudio: true))
    }

    @Test func leavesFinishedAndAudiolessSessionsAlone() {
        #expect(!SessionRecovery.needsFinalPass(
            state: .ready, processingError: nil, hasAudio: true))
        // No audio on disk means nothing to redo the pass from.
        #expect(!SessionRecovery.needsFinalPass(
            state: .processing, processingError: nil, hasAudio: false))
        #expect(!SessionRecovery.needsFinalPass(
            state: .ready, processingError: "Email send failed", hasAudio: true))
    }

    @Test func recordingStateIsOnlyTrustedForTheActiveRecording() {
        #expect(SessionRecovery.isStrandedRecording(
            state: .recording, directoryName: "abc", activeDirectoryName: nil))
        #expect(SessionRecovery.isStrandedRecording(
            state: .recording, directoryName: "abc", activeDirectoryName: "xyz"))
        #expect(!SessionRecovery.isStrandedRecording(
            state: .recording, directoryName: "abc", activeDirectoryName: "abc"))
        #expect(!SessionRecovery.isStrandedRecording(
            state: .processing, directoryName: "abc", activeDirectoryName: nil))
    }

    @Test func findsAudioDirectoriesNoRowPointsAt() {
        let orphans = SessionRecovery.orphanDirectories(
            onDisk: ["kept", "lost-b", "lost-a"], known: ["kept", "gone-from-disk"])
        #expect(orphans == ["lost-a", "lost-b"])
    }

    @Test func liveTranscriptStandsInOnlyWhenItCoversTheRecording() {
        // Covers the whole meeting — re-running the same on-device model over the
        // file would be duplicated work.
        #expect(SessionRecovery.liveTranscriptCovers(
            duration: 600, lastSegmentEnd: 590, hasText: true))
        // Died a minute in: the file pass has real work left to do.
        #expect(!SessionRecovery.liveTranscriptCovers(
            duration: 600, lastSegmentEnd: 60, hasText: true))
        #expect(!SessionRecovery.liveTranscriptCovers(
            duration: 600, lastSegmentEnd: 600, hasText: false))
        // Unmeasurable duration (a truncated container) can't be tested against.
        #expect(SessionRecovery.liveTranscriptCovers(
            duration: 0, lastSegmentEnd: 12, hasText: true))
    }
}
