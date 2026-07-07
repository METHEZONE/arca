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
    /// Renders memory facts as a system-prompt block (empty string when none).
    public static func systemBlock(facts: [MemoryFact]) -> String {
        guard !facts.isEmpty else { return "" }
        let lines = facts
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(40)
            .map { "- \($0.text)" }
            .joined(separator: "\n")
        return """

        Long-term memory — things you already know about the user from earlier \
        conversations. Use them naturally; never recite the list:
        \(lines)
        """
    }
}
