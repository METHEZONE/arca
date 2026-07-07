import Foundation

enum SlackHarvestFilter {
    static func searchQueries(after day: String) -> [String] {
        var terms: [String] = []
        for handle in mentionHandles() {
            terms.append("@\(handle)")
            terms.append(handle)
        }
        for name in selfAliases() where name.count >= 2 && name.lowercased() != "me" {
            terms.append(name)
        }
        terms += [
            "확인 부탁", "처리 부탁", "해줘", "보내줘", "답장 부탁", "핑",
            "please check", "can you", "could you", "need your", "for you",
        ]

        return Array(Set(terms))
            .sorted()
            .prefix(14)
            .map { "\"\($0)\" after:\(day)" }
    }

    static func shouldKeep(text: String, author: String) -> Bool {
        let normalizedText = normalize(text)
        guard !normalizedText.isEmpty else { return false }
        guard !isSelf(author) else { return false }
        return mentionsUser(normalizedText) || containsActionCue(normalizedText)
    }

    static func isSelf(_ author: String) -> Bool {
        let normalizedAuthor = normalize(author)
        guard !normalizedAuthor.isEmpty else { return false }
        return selfAliases().contains { alias in
            let normalizedAlias = normalize(alias)
            return !normalizedAlias.isEmpty &&
                (normalizedAuthor == normalizedAlias || normalizedAuthor.contains(normalizedAlias))
        }
    }

    private static func mentionsUser(_ text: String) -> Bool {
        for handle in mentionHandles() {
            let h = normalize(handle)
            if text.contains("@\(h)") || text.contains(h) { return true }
        }
        for alias in selfAliases() {
            let a = normalize(alias)
            if a.count >= 2, a != "me", text.contains(a) { return true }
        }
        return false
    }

    private static func containsActionCue(_ text: String) -> Bool {
        actionCues.contains { cue in text.contains(normalize(cue)) }
    }

    private static func mentionHandles() -> [String] {
        splitList(UserDefaults.standard.string(forKey: "slackMentionHandles"))
    }

    private static func selfAliases() -> [String] {
        var aliases = splitList(UserDefaults.standard.string(forKey: "slackSelfNames"))
        let owner = UserDefaults.standard.string(forKey: "ownerName") ?? "Me"
        aliases.append(owner)
        return Array(Set(aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
    }

    private static func splitList(_ value: String?) -> [String] {
        (value ?? "")
            .split { $0 == "," || $0 == "\n" || $0 == " " }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static let actionCues = [
        "확인", "처리", "부탁", "해줘", "보내", "답장", "핑", "급", "회의", "일정",
        "check", "please", "can you", "could you", "need", "reply", "send", "review",
        "urgent", "todo", "to-do",
    ]
}
