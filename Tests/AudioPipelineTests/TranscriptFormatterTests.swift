import Foundation
import Testing

@testable import SerialNotes

@Suite("Transcript Formatter")
struct TranscriptFormatterTests {
    @Test("Short entries stay inline")
    func shortEntriesStayInline() {
        let entry = TranscriptFormatter.entry(
            speaker: "You",
            timestamp: 3,
            text: "Hello world."
        )

        #expect(entry == "**You** (00:00:03): Hello world.\n\n")
    }

    @Test("Long entries render as readable paragraphs")
    func longEntriesRenderAsParagraphs() {
        let text = """
        First sentence has enough context to make this transcript entry too long for a compact inline line. Second sentence continues the same speaker turn with more useful detail for the reader. Third sentence closes the first paragraph naturally. Fourth sentence starts a new paragraph instead of extending the wall of text.
        """
        let entry = TranscriptFormatter.entry(
            speaker: "Person 1",
            timestamp: 65,
            text: text
        )

        #expect(entry.hasPrefix("**Person 1** (00:01:05):\n\n"))
        #expect(entry.contains("Third sentence closes the first paragraph naturally.\n\nFourth sentence starts a new paragraph"))
    }
}
