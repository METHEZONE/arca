import XCTest
@testable import ArcaVoiceKit

/// One builder feeds the Obsidian vault, the clipboard, and the nightly digest.
/// These tests are what stop those three from quietly becoming three different
/// documents again.
final class MeetingNoteMarkdownTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ArcaLanguageResolver.apply(.korean)
    }

    override func tearDown() {
        ArcaLanguageResolver.apply(.system)
        super.tearDown()
    }

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private var meetingDate: Date {
        DateComponents(calendar: calendar, timeZone: calendar.timeZone,
                       year: 2026, month: 7, day: 27, hour: 14, minute: 30).date!
    }

    private func content(decisions: [String] = ["가격은 ₩12,900으로 간다"],
                         actions: [String] = ["계약서 초안 (@민성)"]) -> MeetingNoteMarkdown.Content {
        MeetingNoteMarkdown.Content(
            title: "ZER01NE 스프린트 리뷰",
            date: meetingDate,
            summary: "스프린트 3 결과를 검토하고 다음 마일스톤을 정했다.",
            decisions: decisions,
            actionItems: actions,
            sourceLabel: "맥 회의",
            durationSeconds: 52 * 60)
    }

    // MARK: - The three renderings

    func testVaultNoteCarriesFrontmatterForObsidian() {
        let note = MeetingNoteMarkdown.vaultNote(content(), calendar: calendar)

        XCTAssertTrue(note.hasPrefix("---\n"))
        XCTAssertTrue(note.contains("type: meeting"))
        XCTAssertTrue(note.contains("source: arca"))
        XCTAssertTrue(note.contains("capture: 맥 회의"))
        XCTAssertTrue(note.contains("# ZER01NE 스프린트 리뷰"))
    }

    /// Nobody wants `---\ndate: …` pasted into Slack.
    func testClipboardNoteHasNoFrontmatter() {
        let note = MeetingNoteMarkdown.clipboardNote(content(), calendar: calendar)

        XCTAssertFalse(note.contains("---"))
        XCTAssertFalse(note.contains("type: meeting"))
        XCTAssertTrue(note.hasPrefix("# ZER01NE 스프린트 리뷰"))
        XCTAssertTrue(note.contains("스프린트 3 결과를 검토하고"))
    }

    func testBothRenderingsShareTheSameBody() {
        let vault = MeetingNoteMarkdown.vaultNote(content(), calendar: calendar)
        let clipboard = MeetingNoteMarkdown.clipboardNote(content(), calendar: calendar)

        // The vault note is exactly the clipboard note with a header bolted on.
        XCTAssertTrue(vault.contains(clipboard.trimmingCharacters(in: .newlines)))
    }

    /// Actions are checkboxes so they're actionable in Obsidian; decisions are
    /// statements of fact and are not.
    func testActionsAreCheckboxesAndDecisionsAreNot() {
        let note = MeetingNoteMarkdown.clipboardNote(content(), calendar: calendar)

        XCTAssertTrue(note.contains("- [ ] 계약서 초안 (@민성)"))
        XCTAssertTrue(note.contains("- 가격은 ₩12,900으로 간다"))
        XCTAssertFalse(note.contains("- [ ] 가격은"))
    }

    func testEmptySectionsAreOmittedEntirely() {
        let note = MeetingNoteMarkdown.clipboardNote(content(decisions: [], actions: []), calendar: calendar)

        XCTAssertFalse(note.contains("결정사항"))
        XCTAssertFalse(note.contains("액션 아이템"))
        XCTAssertTrue(note.contains("요약"))
    }

    func testDigestSectionNestsUnderADailyNote() {
        let section = MeetingNoteMarkdown.digestSection(content(), calendar: calendar)

        // h2 so several meetings sit under one h1 day heading, with the time first
        // so the day reads chronologically.
        XCTAssertTrue(section.hasPrefix("## 14:30 ZER01NE 스프린트 리뷰"))
        XCTAssertTrue(section.contains("- [ ] 계약서 초안 (@민성)"))
    }

    // MARK: - File naming

    /// The name must be stable across re-exports, or the nightly backfill would
    /// add a duplicate note every time it ran.
    func testFileNameIsStableAndSortsByDay() {
        let name = MeetingNoteMarkdown.fileName(for: content(), calendar: calendar)

        XCTAssertTrue(name.hasPrefix("2026-07-27 "))
        XCTAssertTrue(name.hasSuffix(".md"))
        XCTAssertEqual(name, MeetingNoteMarkdown.fileName(for: content(), calendar: calendar))
    }

    func testSlugifyKeepsKoreanAndSurvivesPunctuation() {
        XCTAssertEqual(MeetingNoteMarkdown.slugify("ZER01NE 스프린트 리뷰"), "zer01ne-스프린트-리뷰")
        XCTAssertEqual(MeetingNoteMarkdown.slugify("Q3 계획 / 예산?!"), "q3-계획-예산")
    }

    /// A title made only of punctuation must not produce a file called ".md".
    func testSlugifyNeverReturnsEmpty() {
        XCTAssertEqual(MeetingNoteMarkdown.slugify("!!!"), "untitled")
        XCTAssertEqual(MeetingNoteMarkdown.slugify(""), "untitled")
    }

    // MARK: - Decoding the store's blobs

    func testDecodesActionItemsWithAssignees() {
        let items = [
            MeetingNotes.ActionItem(text: "계약서 검토", assigneeName: "민성"),
            MeetingNotes.ActionItem(text: "일정 확정", assigneeName: nil),
        ]
        let data = try? JSONEncoder().encode(items)

        let decoded = MeetingNoteMarkdown.decodeActionItems(from: data)

        XCTAssertEqual(decoded, ["계약서 검토 (@민성)", "일정 확정"])
    }

    func testDecodingSurvivesMissingAndCorruptBlobs() {
        XCTAssertEqual(MeetingNoteMarkdown.decodeActionItems(from: nil), [])
        XCTAssertEqual(MeetingNoteMarkdown.decodeDecisions(from: nil), [])
        XCTAssertEqual(MeetingNoteMarkdown.decodeDecisions(from: Data("not json".utf8)), [])
    }

    // MARK: - Language

    func testHeadingsFollowTheLanguage() {
        ArcaLanguageResolver.apply(.english)
        let english = MeetingNoteMarkdown.clipboardNote(content(), calendar: calendar)
        ArcaLanguageResolver.apply(.korean)
        let korean = MeetingNoteMarkdown.clipboardNote(content(), calendar: calendar)

        XCTAssertTrue(english.contains("## Summary"))
        XCTAssertTrue(english.contains("## Action items"))
        XCTAssertTrue(korean.contains("## 요약"))
        XCTAssertTrue(korean.contains("## 액션 아이템"))
        // The user's own content is never translated, only ARCA's scaffolding.
        XCTAssertTrue(english.contains("스프린트 3 결과를 검토하고"))
    }
}
