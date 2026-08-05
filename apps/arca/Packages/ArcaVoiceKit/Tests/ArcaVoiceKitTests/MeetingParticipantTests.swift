import Foundation
import Testing
import ArcaVoiceKit

/// Rules for combining participants that arrive from three places at once —
/// typed by the user, pulled from a calendar invite, read off a meeting screen.
@Suite struct MeetingParticipantTests {
    @Test func sameEmailCollapsesEvenWhenTheNamesDiffer() {
        let typed = [MeetingParticipant(name: "민성", email: "me@thezonebio.com", origin: .typed)]
        let calendar = [MeetingParticipant(name: "MIN SUNG PARK", email: "ME@thezonebio.com",
                                           origin: .calendar)]

        let merged = typed.merging(calendar)

        #expect(merged.count == 1)
        // The hand-typed name is the one the user recognizes on the note.
        #expect(merged[0].name == "민성")
    }

    /// A calendar invite is where the address comes from; a typed name is where
    /// the readable name comes from. Merging has to keep one of each.
    @Test func mergingAdoptsAnEmailWithoutLosingTheTypedName() {
        let typed = [MeetingParticipant(name: "지현", origin: .typed)]
        let calendar = [MeetingParticipant(name: "지현", email: "jihyun@example.com",
                                           origin: .calendar)]

        let merged = typed.merging(calendar)

        #expect(merged.count == 1)
        #expect(merged[0].email == "jihyun@example.com")
        #expect(merged[0].name == "지현")
        #expect(merged[0].origin == .typed)
    }

    @Test func typedNameWinsOverAScreenReading() {
        let screen = [MeetingParticipant(name: "Kim (guest)", origin: .screen)]
        let typed = [MeetingParticipant(name: "Kim (guest)", origin: .typed)]

        let merged = screen.merging(typed)

        #expect(merged.count == 1)
        #expect(merged[0].origin == .typed)
    }

    @Test func distinctPeopleAllSurvive() {
        let merged = [MeetingParticipant(name: "민성", origin: .typed)]
            .merging([MeetingParticipant(name: "지현", origin: .calendar),
                      MeetingParticipant(name: "은희", origin: .screen)])

        #expect(merged.map(\.name) == ["민성", "지현", "은희"])
    }

    /// The owner is excluded: the recognizer wants words that will be spoken,
    /// and people rarely say their own name into their own microphone.
    @Test func vocabularyExcludesTheOwnerAndBlanks() {
        let participants = [
            MeetingParticipant(name: "민성", origin: .typed),
            MeetingParticipant(name: "  ", origin: .typed),
            MeetingParticipant(name: "김은희", origin: .calendar),
        ]

        #expect(participants.vocabulary(excluding: "민성") == ["김은희"])
    }

    @Test func nameAndEmailAreTrimmedOnInit() {
        let participant = MeetingParticipant(name: "  민성 ", email: "  ", origin: .typed)

        #expect(participant.name == "민성")
        #expect(participant.email == nil)
        #expect(participant.id == "민성")
    }
}
