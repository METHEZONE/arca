#if os(macOS)
import Foundation
import SwiftData
import ArcaVoiceKit

@MainActor
@Observable
final class MemoryRemarkProvider {
    private(set) var text: String = ""
    private(set) var isGenerating = false

    func load(ownerName: String,
              facts: [MemoryFact],
              sessions: [RecordingSession],
              chatEntries: [ChatLogEntry]) {
        let key = CompanionHomeLogic.dailyCacheKey(prefix: "arca.memoryRemark")
        if let cached = UserDefaults.standard.string(forKey: key), !cached.isEmpty {
            text = cached
            return
        }

        let earliest = CompanionHomeViewModel.earliestDate(
            sessions: sessions,
            facts: facts,
            chatEntries: chatEntries
        )
        let fallback = CompanionHomeViewModel.fallbackRemark(
            dayCount: CompanionHomeLogic.dayCount(since: earliest),
            memoryCount: facts.count
        )
        text = fallback

        guard !isGenerating,
              let apiKey = KeychainStore.get(.anthropic),
              !apiKey.isEmpty,
              !facts.isEmpty else { return }

        isGenerating = true
        let selected = Self.sampleFacts(facts)
        let model = UserDefaults.standard.string(forKey: "chatModel") ?? "claude-sonnet-5"
        let prompt = """
        너는 ARCA. 아래 기억들로 사용자에게 건네는 따뜻한 한 문장만 작성해라.
        한국어, 40자 내외, 과거 회상 톤. 사실만 말하고 꾸미지 마라.
        사용자 이름: \(ownerName)
        함께한 일수: D+\(CompanionHomeLogic.dayCount(since: earliest))
        기억 수: \(facts.count)
        세션 수: \(sessions.count)
        기억:
        \(selected.map { "- \($0.text)" }.joined(separator: "\n"))
        """

        Task { @MainActor in
            defer { isGenerating = false }
            do {
                let reply = try await ClaudeChat(
                    apiKey: apiKey,
                    model: model,
                    extraSystem: "\nFor this one request, output Korean only, one warm sentence under 40 Korean characters."
                ).reply(to: [ChatMessage(role: .user, parts: [.text(prompt)])], maxTokens: 120)
                let line = reply
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { return }
                text = CompanionHomeLogic.clipped(line, maxCharacters: 48)
                UserDefaults.standard.set(text, forKey: key)
            } catch {
                text = fallback
            }
        }
    }

    private static func sampleFacts(_ facts: [MemoryFact]) -> [MemoryFact] {
        var picked: [MemoryFact] = []
        let oldest = facts.sorted { $0.createdAt < $1.createdAt }.prefix(1)
        let newest = facts.sorted { $0.createdAt > $1.createdAt }.prefix(2)
        for fact in Array(oldest) + Array(newest) {
            if !picked.contains(where: { $0.text == fact.text }) { picked.append(fact) }
        }
        let remaining = facts.filter { fact in
            !picked.contains(where: { $0.text == fact.text })
        }.shuffled().prefix(2)
        picked.append(contentsOf: remaining)
        return picked
    }
}
#endif
