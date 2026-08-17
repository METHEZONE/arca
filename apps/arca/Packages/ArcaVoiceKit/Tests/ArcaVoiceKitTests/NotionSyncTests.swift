import Foundation
import Testing
@testable import ArcaVoiceKit
@testable import ArcaVoiceCore
@testable import Intelligence

/// The 콜드브루 원액 OEM tracker, as it actually exists in Notion.
private let oemSchema = NotionDatabaseSchema(
    id: "db1",
    title: "콜드브루 원액 OEM 관련",
    properties: [
        .init(name: "업체명", kind: .title),
        .init(name: "담당자명", kind: .richText),
        .init(name: "Phone", kind: .phoneNumber),
        .init(name: "Status", kind: .status,
              options: ["Not started", "컨택 대기", "샘플 진행", "계약"]),
    ],
    skippedProperties: ["생성일시"]
)

@Suite struct NotionSchemaDecodingTests {
    @Test func decodesWritableColumnsAndRecordsTheRest() {
        let json: [String: Any] = [
            "id": "db1",
            "title": [["plain_text": "콜드브루 원액 OEM 관련"]],
            "properties": [
                "업체명": ["type": "title", "title": [String: Any]()],
                "Phone": ["type": "phone_number", "phone_number": [String: Any]()],
                "Status": ["type": "status", "status": ["options": [
                    ["name": "Not started"], ["name": "컨택 대기"],
                ]]],
                "정렬": ["type": "formula", "formula": [String: Any]()],
            ],
        ]
        let schema = NotionDatabaseSchema.decode(from: json)
        #expect(schema?.title == "콜드브루 원액 OEM 관련")
        #expect(schema?.properties.map(\.name) == ["Phone", "Status", "업체명"])
        #expect(schema?.titleProperty?.name == "업체명")
        #expect(schema?.property(named: "Status")?.options == ["Not started", "컨택 대기"])
        // A formula column cannot be written, so it must never reach the extractor.
        #expect(schema?.skippedProperties == ["정렬"])
    }
}

@Suite struct NotionPropertyEncoderTests {
    @Test func encodesEachKindInNotionsShape() {
        let phone = NotionPropertyEncoder.payload(
            for: .init(name: "Phone", kind: .phoneNumber), raw: " 010-3289-3198 ")
        #expect(phone?["phone_number"] as? String == "010-3289-3198")

        let status = NotionPropertyEncoder.payload(
            for: oemSchema.property(named: "Status")!, raw: "컨택 대기")
        #expect((status?["status"] as? [String: Any])?["name"] as? String == "컨택 대기")
    }

    @Test func dropsAnOptionTheColumnDoesNotHave() {
        // The model paraphrasing 상태 into something Notion has no option for must
        // leave the cell alone rather than fail the whole PATCH.
        let status = NotionPropertyEncoder.payload(
            for: oemSchema.property(named: "Status")!, raw: "답변 안 옴")
        #expect(status == nil)
    }

    @Test func matchesAnOptionCaseAndSpacingInsensitively() {
        let status = NotionPropertyEncoder.payload(
            for: oemSchema.property(named: "Status")!, raw: "not started")
        #expect((status?["status"] as? [String: Any])?["name"] as? String == "Not started")
    }

    @Test func rejectsValuesThatCannotBeCoerced() {
        #expect(NotionPropertyEncoder.payload(for: .init(name: "n", kind: .number), raw: "약 20kg") == nil)
        #expect(NotionPropertyEncoder.payload(for: .init(name: "e", kind: .email), raw: "배관호대표님") == nil)
        #expect(NotionPropertyEncoder.payload(for: .init(name: "u", kind: .url), raw: "coffeemap.kr") == nil)
        #expect(NotionPropertyEncoder.payload(for: .init(name: "d", kind: .date), raw: "이번주") == nil)
    }

    @Test func acceptsPlainNumbersAndDates() {
        let number = NotionPropertyEncoder.payload(for: .init(name: "n", kind: .number), raw: "1,200")
        #expect(number?["number"] as? Double == 1200)
        let date = NotionPropertyEncoder.payload(for: .init(name: "d", kind: .date), raw: "2026-08-20")
        #expect((date?["date"] as? [String: Any])?["start"] as? String == "2026-08-20")
    }

    @Test func splitsProseTooLongForOneRichTextRun() {
        let long = String(repeating: "가", count: 4500)
        let runs = NotionPropertyEncoder.richText(long)
        #expect(runs.count == 3)
        let first = (runs[0]["text"] as? [String: Any])?["content"] as? String
        #expect(first?.count == 2000)
    }
}

@Suite struct NotionDatabaseReferenceTests {
    @Test func parsesPastedUrlsAndBareIds() throws {
        let id = "1f2e3d4c5b6a79880123456789abcdef"
        #expect(try NotionDBClient.databaseId(from: id) == id)
        #expect(try NotionDBClient.databaseId(
            from: "https://www.notion.so/zone/콜드브루-원액-OEM-관련-\(id)") == id)
        #expect(try NotionDBClient.databaseId(
            from: "1f2e3d4c-5b6a-7988-0123-456789abcdef") == id)
    }

    @Test func ignoresTheViewIdInTheQueryString() throws {
        // `?v=` carries a 32-hex view id too; picking it up produces a
        // "database not found" long after the mistake.
        let id = "1f2e3d4c5b6a79880123456789abcdef"
        let view = "aaaaaaaabbbbccccddddeeeeffff0000"
        #expect(try NotionDBClient.databaseId(
            from: "https://www.notion.so/zone/OEM-\(id)?v=\(view)") == id)
    }

    @Test func rejectsSomethingThatIsNotAReference() {
        #expect(throws: NotionAPIError.self) {
            try NotionDBClient.databaseId(from: "콜드브루 DB")
        }
    }
}

@Suite struct NotionPropertyPlanTests {
    private func extraction(_ properties: [String: String],
                            corrected: Set<String> = []) -> NotionRowExtraction {
        NotionRowExtraction(matchedRowTitle: "커피맵", newRowTitle: nil,
                            properties: properties, correctedProperties: corrected)
    }

    @Test func fillsEmptyColumns() {
        let plan = NotionDBSync.propertyPlan(
            extraction: extraction(["담당자명": "배관호대표님", "Phone": "010-3289-3198"]),
            schema: oemSchema, existing: [:], isNewRow: false)
        #expect(plan.filled == ["Phone", "담당자명"])
        #expect(plan.patch.count == 2)
    }

    @Test func neverOverwritesAValueTheUserAlreadyTyped() {
        // The whole safety story: a wrong Phone silently replacing a right one is
        // not recoverable, so a filled cell stays filled.
        let plan = NotionDBSync.propertyPlan(
            extraction: extraction(["Phone": "010-0000-0000"]),
            schema: oemSchema, existing: ["Phone": "010-3289-3198"], isNewRow: false)
        #expect(plan.filled.isEmpty)
        #expect(plan.preserved == ["Phone"])
        #expect(plan.patch.isEmpty)
    }

    @Test func overwritesOnlyWhenTheMeetingExplicitlyCorrectedIt() {
        let plan = NotionDBSync.propertyPlan(
            extraction: extraction(["Phone": "010-1111-2222"], corrected: ["Phone"]),
            schema: oemSchema, existing: ["Phone": "010-3289-3198"], isNewRow: false)
        #expect(plan.filled == ["Phone"])
    }

    @Test func neverRenamesTheRow() {
        // 업체명 is the title column; rewriting it would break every link into
        // the row.
        let plan = NotionDBSync.propertyPlan(
            extraction: extraction(["업체명": "커피맵(주)"]),
            schema: oemSchema, existing: [:], isNewRow: false)
        #expect(plan.filled.isEmpty)
        #expect(plan.preserved == ["업체명"])
    }

    @Test func skipsWritingBackAnIdenticalValue() {
        let plan = NotionDBSync.propertyPlan(
            extraction: extraction(["Status": "컨택 대기"], corrected: ["Status"]),
            schema: oemSchema, existing: ["Status": "컨택 대기"], isNewRow: false)
        #expect(plan.filled.isEmpty)
        #expect(plan.preserved == ["Status"])
    }

    @Test func reportsColumnsItHadToDrop() {
        let plan = NotionDBSync.propertyPlan(
            extraction: extraction(["Status": "연락 두절"]),
            schema: oemSchema, existing: [:], isNewRow: false)
        #expect(plan.dropped == ["Status"])
        #expect(plan.patch.isEmpty)
    }

    @Test func doesNotRepatchARowItJustCreated() {
        let plan = NotionDBSync.propertyPlan(
            extraction: extraction(["담당자명": "배관호대표님"]),
            schema: oemSchema, existing: [:], isNewRow: true)
        #expect(plan.patch.isEmpty)
    }

    @Test func ignoresAColumnTheDatabaseDoesNotHave() {
        let plan = NotionDBSync.propertyPlan(
            extraction: extraction(["MOQ": "20kg"]),
            schema: oemSchema, existing: [:], isNewRow: false)
        #expect(plan.patch.isEmpty)
        #expect(plan.filled.isEmpty)
    }
}

@Suite struct NotionBodyBlocksTests {
    @Test func dedupesFactsAgainstWhatIsAlreadyOnThePage() {
        let blocks = NotionBodyBlocks.newFactBlocks(
            ["MOQ 20kg", "냉장보관 설비 있음", "moq  20kg"],
            existing: ["냉장보관 설비 있음"])
        #expect(blocks.count == 1)
        let text = ((blocks[0]["bulleted_list_item"] as? [String: Any])?["rich_text"] as? [[String: Any]])
            .flatMap { ($0.first?["text"] as? [String: Any])?["content"] as? String }
        #expect(text == "MOQ 20kg")
    }

    @Test func recognizesAMeetingItAlreadyRecorded() {
        let date = Date(timeIntervalSince1970: 1_786_000_000)
        let headline = NotionBodyBlocks.recordHeadline(title: "커피맵 통화", date: date)
        #expect(NotionBodyBlocks.alreadyRecorded(headline: headline, in: [headline]))
        #expect(!NotionBodyBlocks.alreadyRecorded(headline: headline, in: ["다른 기록"]))
    }

    @Test func statusSectionAlwaysCarriesAnUpdatedStamp() {
        let children = NotionBodyBlocks.statusChildren(
            statusLine: "", nextActions: [], updatedAt: Date(timeIntervalSince1970: 1_786_000_000))
        #expect(children.count == 1)
    }
}

@Suite struct NotionRowReadingTests {
    @Test func readsExistingValuesAsPlainText() {
        let page: [String: Any] = [
            "id": "page1",
            "last_edited_time": "2026-08-14T06:00:00.000Z",
            "properties": [
                "업체명": ["type": "title", "title": [["plain_text": "커피맵"]]],
                "Phone": ["type": "phone_number", "phone_number": "010-3289-3198"],
                "Status": ["type": "status", "status": ["name": "Not started"]],
                "담당자명": ["type": "rich_text", "rich_text": [[String: Any]]()],
            ],
        ]
        let row = NotionDBClient.row(from: page)
        #expect(row?.title == "커피맵")
        #expect(row?.values["Phone"] == "010-3289-3198")
        #expect(row?.values["Status"] == "Not started")
        // An empty cell is absent, which is what lets the plan tell "blank" from
        // "already filled".
        #expect(row?.values["담당자명"] == nil)
        #expect(row?.lastEditedAt != nil)
    }
}
