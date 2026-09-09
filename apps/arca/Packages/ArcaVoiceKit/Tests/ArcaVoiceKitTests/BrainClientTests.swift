import Foundation
import Testing
@testable import ArcaVoiceCore

@Suite struct BrainClientTests {
    static let sample = """
    {
      "views": { "essentials": "- 민성님은 THE ZONE BIO 대표", "threads": "", "recent": "베타 배포 준비 중" },
      "buffer": [
        { "text": "락인커피 원액 9/3 완제", "source": "meeting", "createdAt": "2026-09-08T05:00:00Z" }
      ],
      "pages": [
        { "slug": "people/kim-cs", "title": "김철수", "summary": "OEM 담당, 스틱커피 견적 진행" }
      ],
      "updatedAt": "2026-09-08T05:01:00Z"
    }
    """

    @Test func decodesServerContext() throws {
        let context = try BrainClient.decoder.decode(BrainContext.self, from: Data(Self.sample.utf8))
        #expect(context.views.essentials.contains("THE ZONE BIO"))
        #expect(context.buffer.count == 1)
        #expect(context.pages.first?.slug == "people/kim-cs")
        #expect(context.updatedAt != nil)
        #expect(!context.isEmpty)
    }

    @Test func promptBlockOmitsEmptySectionsAndListsPages() throws {
        let context = try BrainClient.decoder.decode(BrainContext.self, from: Data(Self.sample.utf8))
        let block = context.promptBlock()
        #expect(block.contains("## Essentials"))
        #expect(!block.contains("## Threads"))
        #expect(block.contains("## Recent"))
        #expect(block.contains("· meeting] 락인커피 원액 9/3 완제"))
        #expect(block.contains("- people/kim-cs — OEM 담당"))
    }

    @Test func emptyContextRendersNothing() {
        #expect(BrainContext().promptBlock().isEmpty)
    }

    @Test func promptBlockCapsBufferAndPages() {
        let items = (0..<100).map { BrainContext.BufferItem(text: "fact \($0)", source: "chat", createdAt: .now) }
        let pages = (0..<100).map { BrainContext.PageCard(slug: "p\($0)", title: "t", summary: "s") }
        let block = BrainContext(buffer: items, pages: pages).promptBlock(maxBuffer: 5, maxPages: 3)
        #expect(block.contains("fact 4") && !block.contains("fact 5"))
        #expect(block.contains("- p2 —") && !block.contains("- p3 —"))
    }

    @Test func baseURLDerivesFromCloudURL() {
        #expect(BrainClient.baseURL.absoluteString.hasSuffix("/api/brain"))
    }

    @Test func eventsPayloadEncodesKindsInOrder() throws {
        let data = try #require(BrainClient.eventsPayload(["app_open", "loop_closed"]))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let events = try #require(json?["events"] as? [[String: Any]])
        #expect(events.count == 2)
        #expect(events[0]["kind"] as? String == "app_open")
        #expect(events[1]["kind"] as? String == "loop_closed")
        #expect(BrainClient.eventsPayload([]) == nil)
    }
}
