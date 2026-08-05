import Foundation
import SwiftData
import Testing
@testable import ArcaVoiceKit

/// What the relay is allowed to do to a transcript that already exists.
///
/// These exist because of a real cross-device loss: only `isFinal` segments were
/// put on the wire, so a recording whose cloud pass hadn't landed crossed as a
/// session with an empty transcript — and the receiving side deleted its own
/// lines to match. One device's failure erased another device's words over the
/// network, on a machine that had run nothing.
@Suite @MainActor struct SessionWireMergeTests {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            RecordingSession.self, AudioAsset.self, StoredSegment.self,
            SpeakerRecord.self, SessionNote.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func session(_ context: ModelContext, uid: String = "uid-1",
                         segments: [(String, Bool)]) -> RecordingSession {
        let record = RecordingSession(title: "회의", source: .macMeeting, directoryName: uid)
        record.state = .ready
        for (index, entry) in segments.enumerated() {
            record.segments.append(StoredSegment(
                text: entry.0, start: Double(index), end: Double(index) + 1,
                channel: .microphone, isFinal: entry.1))
        }
        context.insert(record)
        return record
    }

    @Test func emptyRemoteNeverErasesALocalTranscript() throws {
        let context = try makeContext()
        let local = session(context, segments: [("여기 중요한 얘기가 있었어요", false)])
        let remote = session(context, uid: "uid-remote", segments: [])

        var wire = SessionWire(remote)
        wire.title = "덮어쓰기 시도"
        wire.apply(to: local, context: context)

        #expect(local.segments.count == 1)
        #expect(local.segments.first?.text == "여기 중요한 얘기가 있었어요")
        // Scalars still follow the newer payload — only the transcript is guarded.
        #expect(local.title == "덮어쓰기 시도")
    }

    /// The reason live segments now travel at all.
    @Test func liveOnlyRemoteFillsAnEmptyLocalTranscript() throws {
        let context = try makeContext()
        let local = session(context, segments: [])
        let remote = session(context, uid: "uid-remote", segments: [("폰에서 받아적은 말", false)])

        SessionWire(remote).apply(to: local, context: context)

        #expect(local.segments.count == 1)
        // Relayed as live, so the receiving device still knows to improve it.
        #expect(local.segments.first?.isFinal == false)
    }

    @Test func liveRemoteDoesNotDowngradeAFinalLocalTranscript() throws {
        let context = try makeContext()
        let local = session(context, segments: [("화자분리까지 끝난 문장", true)])
        let remote = session(context, uid: "uid-remote", segments: [("거친 기기 전사", false)])

        SessionWire(remote).apply(to: local, context: context)

        #expect(local.segments.first?.text == "화자분리까지 끝난 문장")
        #expect(local.segments.first?.isFinal == true)
    }

    @Test func finalRemoteReplacesALiveLocalTranscript() throws {
        let context = try makeContext()
        let local = session(context, segments: [("거친 기기 전사", false)])
        let remote = session(context, uid: "uid-remote", segments: [("좋은 전사", true)])

        SessionWire(remote).apply(to: local, context: context)

        #expect(local.segments.count == 1)
        #expect(local.segments.first?.text == "좋은 전사")
        #expect(local.segments.first?.isFinal == true)
    }

    /// Payloads written before `isFinal` existed carried only final segments, so
    /// a missing flag has to read as final — otherwise every older relay file
    /// would look like a downgrade and stop being applied.
    @Test func absentIsFinalIsTreatedAsFinal() throws {
        let context = try makeContext()
        let local = session(context, segments: [("거친 기기 전사", false)])
        let remote = session(context, uid: "uid-remote", segments: [("예전 릴레이 문장", true)])

        var wire = SessionWire(remote)
        wire.segments[0].isFinal = nil
        wire.apply(to: local, context: context)

        #expect(local.segments.first?.text == "예전 릴레이 문장")
        #expect(local.segments.first?.isFinal == true)
    }
}
