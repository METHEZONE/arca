import Foundation
import SwiftData

/// One long-term memory ARCA keeps about the user — a fact, preference, or
/// ongoing project. Injected into every chat's system prompt so ARCA stays
/// the same companion across conversations (and, once sync lands, devices).
@Model
public final class MemoryFact {
    public var text: String
    public var createdAt: Date
    /// user | preference | project | fact
    public var kindRaw: String
    /// Where it was learned: chat, meeting, manual.
    public var sourceRaw: String

    public init(text: String, kind: String = "fact", source: String = "chat",
                createdAt: Date = .now) {
        self.text = text
        self.kindRaw = kind
        self.sourceRaw = source
        self.createdAt = createdAt
    }
}

public enum MemoryPrompt {
    /// Same cap used for both the chat system-prompt block and the dedup list
    /// handed to `MemoryExtractor` — without one, either list grows with every
    /// fact ever recorded and the prompt cost grows unbounded forever.
    static let recentFactCap = 200

    /// Renders memory facts as a system-prompt block (empty string when none).
    ///
    /// 40 was measured against nothing — Sonnet 5 runs a 1M-token context, and
    /// a couple hundred short facts costs a few thousand tokens, negligible.
    /// The real fix for "too much history" is relevance ranking, not a tiny
    /// cap; this is the cheap intermediate step until that's worth building.
    public static func systemBlock(facts: [MemoryFact]) -> String {
        guard !facts.isEmpty else { return "" }
        let lines = recentFacts(facts)
            .map { "- \($0.text)" }
            .joined(separator: "\n")
        return """

        Long-term memory — things you already know about the user from earlier \
        conversations. Use them naturally; never recite the list:
        \(lines)
        """
    }

    /// The "already known" list passed to `MemoryExtractor` so it doesn't
    /// re-extract the same fact from every future chat or meeting. Capped the
    /// same way as `systemBlock` — every call site used to fetch every
    /// `MemoryFact` ever recorded, so a year of daily use meant a
    /// thousand-line prompt on every single conversation.
    public static func knownFactsForDedup(_ facts: [MemoryFact]) -> [String] {
        recentFacts(facts).map(\.text)
    }

    private static func recentFacts(_ facts: [MemoryFact]) -> [MemoryFact] {
        Array(facts.sorted { $0.createdAt > $1.createdAt }.prefix(recentFactCap))
    }
}
