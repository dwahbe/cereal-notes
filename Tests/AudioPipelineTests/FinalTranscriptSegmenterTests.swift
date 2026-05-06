import FluidAudio
import Foundation
import Testing

@testable import SerialNotes

@Suite("Final Transcript Segmenter")
struct FinalTranscriptSegmenterTests {
    @Test("Falls back to result text when token timings are missing")
    func fallbackWithoutTimings() {
        let result = ASRResult(
            text: "Hello world.",
            confidence: 1,
            duration: 4,
            processingTime: 0.1
        )

        let segments = FinalTranscriptSegmenter.segments(from: result)

        #expect(segments.count == 1)
        #expect(segments.first?.text == "Hello world.")
        #expect(segments.first?.start == 0)
        #expect(segments.first?.end == 4)
    }

    @Test("Breaks on timing gaps")
    func breaksOnTimingGaps() {
        let result = ASRResult(
            text: "",
            confidence: 1,
            duration: 8,
            processingTime: 0.1,
            tokenTimings: [
                token(" Hello", start: 0.0, end: 0.2),
                token(" world", start: 0.2, end: 0.4),
                token(".", start: 0.4, end: 0.5),
                token(" Next", start: 2.0, end: 2.2),
                token(" thought", start: 2.2, end: 2.4),
                token(".", start: 2.4, end: 2.5)
            ]
        )

        let segments = FinalTranscriptSegmenter.segments(from: result)

        #expect(segments.map(\.text) == ["Hello world.", "Next thought."])
        #expect(segments.map(\.start) == [0.0, 2.0])
    }

    @Test("Normalizes spaces before punctuation")
    func normalizesPunctuationSpacing() {
        let result = ASRResult(
            text: "",
            confidence: 1,
            duration: 2,
            processingTime: 0.1,
            tokenTimings: [
                token(" Hello", start: 0.0, end: 0.1),
                token(" world", start: 0.1, end: 0.2),
                token(" ,", start: 0.2, end: 0.3),
                token(" again", start: 0.3, end: 0.4),
                token(" !", start: 0.4, end: 0.5)
            ]
        )

        let segments = FinalTranscriptSegmenter.segments(from: result)

        #expect(segments.first?.text == "Hello world, again!")
    }

    private func token(_ text: String, start: TimeInterval, end: TimeInterval) -> TokenTiming {
        TokenTiming(
            token: text,
            tokenId: 0,
            startTime: start,
            endTime: end,
            confidence: 1
        )
    }
}
