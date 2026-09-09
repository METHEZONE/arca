import Foundation
import Testing
import ArcaVoiceKit

@Suite struct MemoryPromptTests {
    @Test func knownFactsForDedupCapsToMostRecentTwoHundred() {
        let facts = (0..<250).map { i in
            MemoryFact(text: "fact-\(i)", createdAt: Date(timeIntervalSince1970: Double(i)))
        }

        let known = MemoryPrompt.knownFactsForDedup(facts)

        // Without a cap, a year of daily meetings feeds a thousand-line list
        // into every extraction call — this pins the ceiling in place.
        #expect(known.count == 200)
        #expect(known.first == "fact-249")
        #expect(!known.contains("fact-0"))
    }

    @Test func systemBlockIsEmptyForNoFacts() {
        #expect(MemoryPrompt.systemBlock(facts: []).isEmpty)
    }
}
