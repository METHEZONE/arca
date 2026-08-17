import Foundation
import ArcaVoiceCore

public struct NotionSyncOutcome: Sendable, Equatable {
    public let pageId: String
    public let rowTitle: String
    public let createdRow: Bool
    /// Columns ARCA actually wrote.
    public let filledColumns: [String]
    /// Columns the transcript spoke to but that already held a value — left alone.
    public let preservedColumns: [String]
    /// Columns whose value could not be coerced into the column's kind.
    public let droppedColumns: [String]
    public let addedFacts: Int
    public let recordedHistory: Bool

    /// A one-line Korean summary for the notch notice.
    public var noticeText: String {
        var parts: [String] = []
        parts.append(createdRow ? "\(rowTitle) 행을 새로 만들었어요" : "\(rowTitle) 업데이트")
        if !filledColumns.isEmpty {
            parts.append("채운 칸: \(filledColumns.joined(separator: ", "))")
        }
        if addedFacts > 0 { parts.append("사실 \(addedFacts)개 추가") }
        if !preservedColumns.isEmpty {
            parts.append("이미 값이 있어 건드리지 않음: \(preservedColumns.joined(separator: ", "))")
        }
        return parts.joined(separator: " · ")
    }
}

public enum NotionSyncResult: Sendable, Equatable {
    case synced(NotionSyncOutcome)
    /// The transcript was not about any row, and the model proposed no new one.
    case noSubject
}

/// Keeps one Notion database row current from one meeting.
///
/// Two rules make this safe enough to run unattended:
///
///  1. **A value the user typed is never overwritten.** A column is written only
///     when it is empty, or when the extractor explicitly flagged the meeting as
///     correcting it. Getting a blank Status filled is useful; getting a wrong
///     Phone silently replaced is not recoverable.
///  2. **The page body is only ever added to.** ARCA writes inside the three
///     toggles it owns (see `NotionBodyBlocks`) and never deletes or rewrites a
///     block the user made. Only the 현재 상태 toggle's own children are replaced.
///
/// The title column is also never rewritten on an existing row — renaming 업체명
/// out from under the user would break every link pointing at it.
public struct NotionDBSync: Sendable {
    private let client: NotionDBClient
    private let extractor: NotionFieldExtractor

    public init(client: NotionDBClient, extractor: NotionFieldExtractor) {
        self.client = client
        self.extractor = extractor
    }

    /// Builds a sync from ~/.arca/connections.json plus an Anthropic key; nil
    /// when either is missing.
    public static func fromArcaConfig(anthropicKey: String?) -> NotionDBSync? {
        guard let client = NotionDBClient.fromArcaConfig(),
              let anthropicKey, !anthropicKey.isEmpty else { return nil }
        return NotionDBSync(client: client,
                            extractor: NotionFieldExtractor(apiKey: anthropicKey))
    }

    /// - Parameter allowRowCreation: whether a transcript that matches no
    ///   existing row may create one. Off by default at every call site: with
    ///   auto-sync on, every meeting reaches this code, including ones that have
    ///   nothing to do with the database — and a model that stretches to fill
    ///   `new_row_title` would litter the user's tracker with rows named after
    ///   standups. Updating a row the user already made carries no such risk.
    public func run(
        databaseId: String,
        transcript: AttributedTranscript,
        notes: MeetingNotes?,
        meetingTitle: String,
        meetingDate: Date,
        allowRowCreation: Bool = false
    ) async throws -> NotionSyncResult {
        let schema = try await client.fetchSchema(databaseId: databaseId)
        let (rows, truncated) = try await client.fetchRows(databaseId: databaseId)
        if truncated {
            NSLog("[ArcaVoice] notion sync: row list truncated at %d rows — matching against a partial list", rows.count)
        }

        let extraction = try await extractor.extract(
            schema: schema, rows: rows, transcript: transcript,
            notes: notes, meetingDate: meetingDate)

        guard let target = try await resolveTarget(
            extraction: extraction, schema: schema, rows: rows, databaseId: databaseId,
            allowRowCreation: allowRowCreation)
        else { return .noSubject }

        let plan = Self.propertyPlan(extraction: extraction, schema: schema,
                                     existing: target.existingValues,
                                     isNewRow: target.created)
        if !plan.patch.isEmpty {
            try await client.updateProperties(pageId: target.pageId, properties: plan.patch)
        }

        let body = try await syncBody(pageId: target.pageId, extraction: extraction,
                                      meetingTitle: meetingTitle, meetingDate: meetingDate,
                                      notes: notes)

        return .synced(NotionSyncOutcome(
            pageId: target.pageId,
            rowTitle: target.title,
            createdRow: target.created,
            filledColumns: plan.filled,
            preservedColumns: plan.preserved,
            droppedColumns: plan.dropped,
            addedFacts: body.addedFacts,
            recordedHistory: body.recordedHistory))
    }

    // MARK: - Row resolution

    private struct Target {
        let pageId: String
        let title: String
        let created: Bool
        let existingValues: [String: String]
    }

    private func resolveTarget(extraction: NotionRowExtraction,
                               schema: NotionDatabaseSchema,
                               rows: [NotionDBClient.Row],
                               databaseId: String,
                               allowRowCreation: Bool) async throws -> Target? {
        if let matched = extraction.matchedRowTitle,
           let row = rows.first(where: { $0.title == matched }) {
            return Target(pageId: row.id, title: row.title, created: false,
                          existingValues: row.values)
        }
        guard allowRowCreation else { return nil }
        guard let newTitle = extraction.newRowTitle,
              let titleProperty = schema.titleProperty,
              let payload = NotionPropertyEncoder.payload(for: titleProperty, raw: newTitle)
        else { return nil }

        var properties: [String: Any] = [titleProperty.name: payload]
        // Seed the new row with everything the meeting established — nothing can
        // be overwritten on a row that did not exist a moment ago.
        for (name, raw) in extraction.properties where name != titleProperty.name {
            guard let property = schema.property(named: name),
                  let value = NotionPropertyEncoder.payload(for: property, raw: raw) else { continue }
            properties[name] = value
        }
        let pageId = try await client.createRow(databaseId: databaseId, properties: properties)
        return Target(pageId: pageId, title: newTitle, created: true, existingValues: [:])
    }

    // MARK: - Property planning

    struct PropertyPlan: Equatable {
        var patch: [String: Any] = [:]
        var filled: [String] = []
        var preserved: [String] = []
        var dropped: [String] = []

        static func == (lhs: PropertyPlan, rhs: PropertyPlan) -> Bool {
            lhs.filled == rhs.filled && lhs.preserved == rhs.preserved
                && lhs.dropped == rhs.dropped && lhs.patch.keys.sorted() == rhs.patch.keys.sorted()
        }
    }

    /// Decides which columns may be written. Pure so the safety rules are
    /// testable without a network.
    static func propertyPlan(extraction: NotionRowExtraction,
                             schema: NotionDatabaseSchema,
                             existing: [String: String],
                             isNewRow: Bool) -> PropertyPlan {
        var plan = PropertyPlan()
        // A brand-new row was already seeded at creation; re-patching it would
        // only repeat the same values.
        guard !isNewRow else { return plan }

        for name in extraction.properties.keys.sorted() {
            guard let raw = extraction.properties[name],
                  let property = schema.property(named: name) else { continue }

            // Renaming the row out from under the user breaks every link to it.
            if property.kind == .title { plan.preserved.append(name); continue }

            let current = existing[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !current.isEmpty && !extraction.correctedProperties.contains(name) {
                plan.preserved.append(name)
                continue
            }
            guard let payload = NotionPropertyEncoder.payload(for: property, raw: raw) else {
                plan.dropped.append(name)
                continue
            }
            // Writing the identical value back is a no-op that still burns a
            // "last edited by ARCA" stamp on the row.
            if current == raw.trimmingCharacters(in: .whitespacesAndNewlines) {
                plan.preserved.append(name)
                continue
            }
            plan.patch[name] = payload
            plan.filled.append(name)
        }
        return plan
    }

    // MARK: - Body

    private struct BodyOutcome {
        let addedFacts: Int
        let recordedHistory: Bool
    }

    private func syncBody(pageId: String, extraction: NotionRowExtraction,
                          meetingTitle: String, meetingDate: Date,
                          notes: MeetingNotes?) async throws -> BodyOutcome {
        let topLevel = try await client.children(of: pageId)

        func ownedToggle(_ heading: String) -> NotionDBClient.Block? {
            topLevel.first { $0.type == "toggle" && $0.text == heading }
        }

        // 1) 현재 상태 — children replaced so it always reads as "right now".
        let statusChildren = NotionBodyBlocks.statusChildren(
            statusLine: extraction.statusLine,
            nextActions: extraction.nextActions,
            updatedAt: meetingDate)
        if let existing = ownedToggle(NotionBodyBlocks.statusHeading) {
            try await client.replaceChildren(of: existing.id, with: statusChildren)
        } else {
            try await client.appendChildren(to: pageId, blocks: [
                NotionBodyBlocks.toggle(NotionBodyBlocks.statusHeading, children: statusChildren)
            ])
        }

        // 2) 확인된 사실 — appended, deduped against what is already listed.
        var addedFacts = 0
        if !extraction.facts.isEmpty {
            if let existing = ownedToggle(NotionBodyBlocks.factsHeading) {
                let current = try await client.children(of: existing.id).map(\.text)
                let blocks = NotionBodyBlocks.newFactBlocks(extraction.facts, existing: current)
                if !blocks.isEmpty {
                    try await client.appendChildren(to: existing.id, blocks: blocks)
                    addedFacts = blocks.count
                }
            } else {
                let blocks = NotionBodyBlocks.newFactBlocks(extraction.facts, existing: [])
                try await client.appendChildren(to: pageId, blocks: [
                    NotionBodyBlocks.toggle(NotionBodyBlocks.factsHeading, children: blocks)
                ])
                addedFacts = blocks.count
            }
        }

        // 3) 기록 — one entry per meeting, skipped when this meeting is already in.
        let headline = NotionBodyBlocks.recordHeadline(title: meetingTitle, date: meetingDate)
        let record = NotionBodyBlocks.recordBlock(
            title: meetingTitle, date: meetingDate,
            summary: notes?.summaryMarkdown ?? "")
        var recorded = false
        if let existing = ownedToggle(NotionBodyBlocks.recordHeading) {
            let current = try await client.children(of: existing.id).map(\.text)
            if !NotionBodyBlocks.alreadyRecorded(headline: headline, in: current) {
                try await client.appendChildren(to: existing.id, blocks: [record])
                recorded = true
            }
        } else {
            try await client.appendChildren(to: pageId, blocks: [
                NotionBodyBlocks.toggle(NotionBodyBlocks.recordHeading, children: [record])
            ])
            recorded = true
        }

        return BodyOutcome(addedFacts: addedFacts, recordedHistory: recorded)
    }
}
