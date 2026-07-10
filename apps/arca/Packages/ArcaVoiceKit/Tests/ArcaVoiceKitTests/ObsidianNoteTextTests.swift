import Testing
import ArcaVoiceKit

@Suite struct ObsidianNoteTextTests {
    @Test func stripsYAMLFrontmatterBeforeBuildingPreview() {
        let markdown = """
        ---
        title: Private metadata
        tags:
          - arca
        ---

        # Real Note

        First useful line.

        Second useful line.
        """

        #expect(ObsidianNoteText.removingYAMLFrontmatter(from: markdown).hasPrefix("# Real Note"))
        #expect(ObsidianNoteText.preview(from: markdown) == "# Real Note First useful line. Second useful line.")
    }

    @Test func leavesBodyAloneWhenOpeningFenceIsNotFrontmatter() {
        let markdown = "--- not frontmatter\nBody"

        #expect(ObsidianNoteText.removingYAMLFrontmatter(from: markdown) == markdown)
    }

    @Test func limitsPreviewAfterCollapsingNonEmptyLines() {
        let markdown = """
        Alpha

        Beta Gamma Delta
        """

        #expect(ObsidianNoteText.preview(from: markdown, limit: 10) == "Alpha Beta")
    }
}
