import FluidAudio
import Foundation

struct FinalTranscriptSegment {
    let text: String
    let start: TimeInterval
    let end: TimeInterval

    var midpoint: TimeInterval {
        (start + end) / 2
    }
}

enum FinalTranscriptSegmenter {
    private static let segmentGapThreshold: TimeInterval = 1.2
    private static let maxSegmentDuration: TimeInterval = 30
    private static let maxSegmentWords = 80
    private static let minWordsForSentenceBreak = 14

    static func segments(from result: ASRResult) -> [FinalTranscriptSegment] {
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            let text = normalizedText(result.text)
            guard !text.isEmpty else { return [] }
            return [FinalTranscriptSegment(text: text, start: 0, end: result.duration)]
        }

        var segments: [FinalTranscriptSegment] = []
        var current: [TokenTiming] = []
        var currentWordCount = 0

        for timing in timings {
            if let previous = current.last,
               shouldBreak(
                   before: timing,
                   after: previous,
                   segmentStart: current[0].startTime,
                   wordCount: currentWordCount
               ) {
                appendSegment(current, to: &segments)
                current.removeAll(keepingCapacity: true)
                currentWordCount = 0
            }

            current.append(timing)
            currentWordCount += wordCount(in: timing.token)
        }

        appendSegment(current, to: &segments)
        return segments
    }

    private static func shouldBreak(
        before token: TokenTiming,
        after previous: TokenTiming,
        segmentStart: TimeInterval,
        wordCount: Int
    ) -> Bool {
        let gap = token.startTime - previous.endTime
        if gap >= segmentGapThreshold { return true }

        let duration = previous.endTime - segmentStart
        if duration >= maxSegmentDuration { return true }
        if wordCount >= maxSegmentWords { return true }

        return TranscriptTextProcessing.hasTerminalPunctuation(previous.token) && wordCount >= minWordsForSentenceBreak
    }

    private static func appendSegment(_ timings: [TokenTiming], to segments: inout [FinalTranscriptSegment]) {
        guard let first = timings.first, let last = timings.last else { return }
        let text = normalizedText(timings.map(\.token).joined())
        guard !text.isEmpty else { return }

        segments.append(FinalTranscriptSegment(
            text: text,
            start: first.startTime,
            end: max(last.endTime, first.startTime)
        ))
    }

    private static func normalizedText(_ text: String) -> String {
        var collapsed = ""
        var previousWasWhitespace = false

        for character in text {
            if character.isWhitespace {
                if !collapsed.isEmpty && !previousWasWhitespace {
                    collapsed.append(" ")
                    previousWasWhitespace = true
                }
            } else {
                if isPunctuation(character), collapsed.last == " " {
                    collapsed.removeLast()
                }
                collapsed.append(character)
                previousWasWhitespace = false
            }
        }

        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func wordCount(in text: String) -> Int {
        // Counts words within a single token, e.g. "Q&A" -> 2; do not unify with whitespace word counts.
        text.split { character in
            !character.isLetter && !character.isNumber
        }.count
    }

    private static func isPunctuation(_ character: Character) -> Bool {
        character == "." ||
            character == "," ||
            character == "!" ||
            character == "?" ||
            character == ";" ||
            character == ":"
    }
}
