import Foundation
import ArcaVoiceCore

/// Builds the blocks ARCA owns on a Notion page, and nothing else.
///
/// The page body is the user's — 콜드브루 OEM rows carry hand-typed call notes,
/// and losing those to an automated "sync" would be worse than having no sync.
/// So ARCA writes only inside three toggles it creates and recognizes by their
/// exact heading text:
///
///   ⚡ ARCA 현재 상태   children replaced every sync (the latest state)
///   📌 ARCA 확인된 사실  children appended, deduped by text (durable specs)
///   🗓 ARCA 기록        children appended, one entry per meeting (history)
///
/// Splitting "latest" from "history" is what makes both possible: re-running the
/// same meeting refreshes the state without stacking duplicates, while a second
/// meeting adds to the record instead of erasing the first.
public enum NotionBodyBlocks {
    public static let statusHeading = "⚡ ARCA 현재 상태"
    public static let factsHeading = "📌 ARCA 확인된 사실"
    public static let recordHeading = "🗓 ARCA 기록"

    public static var ownedHeadings: [String] {
        [statusHeading, factsHeading, recordHeading]
    }

    // MARK: - Block primitives

    public static func toggle(_ heading: String,
                              children: [[String: Any]] = []) -> [String: Any] {
        var body: [String: Any] = ["rich_text": NotionPropertyEncoder.richText(heading)]
        if !children.isEmpty { body["children"] = children }
        return ["object": "block", "type": "toggle", "toggle": body]
    }

    public static func paragraph(_ text: String) -> [String: Any] {
        ["object": "block", "type": "paragraph",
         "paragraph": ["rich_text": NotionPropertyEncoder.richText(text)]]
    }

    public static func bullet(_ text: String) -> [String: Any] {
        ["object": "block", "type": "bulleted_list_item",
         "bulleted_list_item": ["rich_text": NotionPropertyEncoder.richText(text)]]
    }

    // MARK: - Section contents

    /// The children of ⚡ ARCA 현재 상태. Replaced wholesale on every sync, so it
    /// always reads as "where this stands right now".
    public static func statusChildren(statusLine: String, nextActions: [String],
                                     updatedAt: Date) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        if !statusLine.isEmpty {
            blocks.append(paragraph("상태 · \(statusLine)"))
        }
        if !nextActions.isEmpty {
            blocks.append(paragraph("다음 액션"))
            blocks.append(contentsOf: nextActions.map { bullet($0) })
        }
        blocks.append(paragraph("마지막 업데이트 · \(timestamp(updatedAt)) · ARCA"))
        return blocks
    }

    /// New fact bullets, skipping any whose text is already on the page. Notion
    /// has no set semantics, so dedup happens here against what was read back.
    public static func newFactBlocks(_ facts: [String],
                                     existing: [String]) -> [[String: Any]] {
        var seen = Set(existing.map(normalize))
        var blocks: [[String: Any]] = []
        for fact in facts {
            let key = normalize(fact)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            blocks.append(bullet(fact))
        }
        return blocks
    }

    /// The visible title of one history entry. Doubles as its identity: a re-run
    /// of the same meeting produces the same headline and is skipped. Notion
    /// blocks carry no custom metadata, and an id embedded in the text would be
    /// visible on the page — the timestamp already distinguishes meetings, so it
    /// is the marker.
    public static func recordHeadline(title: String, date: Date) -> String {
        "\(timestamp(date)) · \(title.isEmpty ? "기록" : title)"
    }

    public static func recordBlock(title: String, date: Date, summary: String) -> [String: Any] {
        var children: [[String: Any]] = []
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            // Notion caps a single append at 100 children, and each paragraph run
            // at 2000 characters; a long summary becomes several paragraphs.
            for line in trimmed.components(separatedBy: "\n")
            where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                children.append(paragraph(line))
            }
        }
        return toggle(recordHeadline(title: title, date: date),
                      children: Array(children.prefix(100)))
    }

    /// Whether this meeting is already in the record section.
    public static func alreadyRecorded(headline: String, in existing: [String]) -> Bool {
        let key = normalize(headline)
        return existing.contains { normalize($0) == key }
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.isWhitespace }
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
