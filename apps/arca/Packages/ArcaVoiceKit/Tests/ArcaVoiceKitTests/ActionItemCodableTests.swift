import Foundation
import Testing
import ArcaVoiceKit

@Suite struct ActionItemCodableTests {
    @Test func decodesOldActionItemJSONWithoutLinkFields() throws {
        let json = """
        [
          {"text": "디자인 시안 준비", "assigneeName": "민성"},
          {"text": "QA 계획 작성"}
        ]
        """
        let items = try JSONDecoder().decode([MeetingNotes.ActionItem].self, from: Data(json.utf8))

        #expect(items.count == 2)
        #expect(items[0].text == "디자인 시안 준비")
        #expect(items[0].assigneeName == "민성")
        #expect(items[0].id == nil)
        #expect(items[0].todoTaskUID == nil)
        #expect(items[0].calendarEventID == nil)
        #expect(items[0].isLinked == false)
        #expect(items[1].assigneeName == nil)
    }

    @Test func actionItemLinkFieldsRoundTrip() throws {
        let id = UUID()
        let due = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let original = MeetingNotes.ActionItem(
            id: id,
            text: "후속 메일 보내기",
            assigneeName: "Me",
            due: due,
            todoTaskUID: "task-123",
            calendarEventID: "event-456"
        )

        let data = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([MeetingNotes.ActionItem].self, from: data)

        #expect(decoded.count == 1)
        #expect(decoded[0].id == id)
        #expect(decoded[0].text == original.text)
        #expect(decoded[0].assigneeName == "Me")
        #expect(decoded[0].due == due)
        #expect(decoded[0].todoTaskUID == "task-123")
        #expect(decoded[0].calendarEventID == "event-456")
        #expect(decoded[0].isLinked)
    }
}
