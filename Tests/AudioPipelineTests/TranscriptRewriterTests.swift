import Foundation
import Testing

@testable import SerialNotes

@Suite("Transcript Rewriter")
struct TranscriptRewriterTests {
    @Test("Heuristic: capitalizes first letter and adds period")
    func heuristicCapitalizesAndAppendsPeriod() async {
        let rewriter = HeuristicRewriter()
        let result = await rewriter.rewrite("hello world")
        #expect(result == "Hello world.")
    }

    @Test("Heuristic: preserves existing terminal punctuation")
    func heuristicPreservesExistingPunctuation() async {
        let rewriter = HeuristicRewriter()
        #expect(await rewriter.rewrite("hello world.") == "Hello world.")
        #expect(await rewriter.rewrite("hello world!") == "Hello world!")
        #expect(await rewriter.rewrite("hello world?") == "Hello world?")
    }

    @Test("Heuristic: leaves already-capitalized text alone (except period)")
    func heuristicLeavesCapitalAlone() async {
        let rewriter = HeuristicRewriter()
        let result = await rewriter.rewrite("Hello world")
        #expect(result == "Hello world.")
    }

    @Test("Heuristic: empty input stays empty")
    func heuristicEmptyInput() async {
        let rewriter = HeuristicRewriter()
        #expect(await rewriter.rewrite("") == "")
        #expect(await rewriter.rewrite("   ") == "")
    }

    @Test("Heuristic: single word")
    func heuristicSingleWord() async {
        let rewriter = HeuristicRewriter()
        #expect(await rewriter.rewrite("hi") == "Hi.")
    }

    @Test("Heuristic: strips surrounding whitespace before processing")
    func heuristicTrimsWhitespace() async {
        let rewriter = HeuristicRewriter()
        #expect(await rewriter.rewrite("  hello world  ") == "Hello world.")
    }

    @Test("Heuristic: adds sentence breaks to long ASR chunks")
    func heuristicBreaksLongChunks() async {
        let rewriter = HeuristicRewriter()
        let input = "we need to review the roadmap with enough context for everyone so now we can decide what changes matter and finally we should capture the follow up clearly"
        let result = await rewriter.rewrite(input)

        #expect(result.contains(". So now"), "Expected discourse sentence break, got '\(result)'")
        #expect(result.contains(". Finally"), "Expected final transition sentence break, got '\(result)'")

        let normalize: (String) -> String = { s in
            s.lowercased().unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0)
            }.map(String.init).joined()
        }
        #expect(normalize(result) == normalize(input), "Word sequence changed: '\(result)'")
    }

    @Test("Heuristic: collapses obvious immediate ASR repetitions")
    func heuristicCollapsesImmediateRepeats() async {
        let rewriter = HeuristicRewriter()
        let input = "we will work with work with work with partners because this is really really really important"
        let result = await rewriter.rewrite(input)

        #expect(result == "We will work with partners because this is really really important.")
    }

    /// End-to-end smoke test against Apple Foundation Models. Skipped unless
    /// `SERIAL_FM_TEST=1` because `swift test` runs outside the `.app` bundle
    /// and Apple Intelligence availability depends on the host.
    @Test(
        "FoundationModels smoke test (gated by SERIAL_FM_TEST)",
        .enabled(if: ProcessInfo.processInfo.environment["SERIAL_FM_TEST"] == "1")
    )
    func foundationModelsSmokeTest() async {
        let rewriter = FoundationModelsRewriter()
        let input = "hello world this is a test of punctuation"
        let result = await rewriter.rewrite(input)

        #expect(result.first?.isUppercase == true, "Expected capital first letter, got '\(result)'")
        #expect("!?.".contains(result.last ?? " "), "Expected terminal punctuation, got '\(result)'")

        let normalize: (String) -> String = { s in
            s.lowercased().unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0)
            }.map(String.init).joined()
        }
        #expect(normalize(result) == normalize(input), "Word sequence changed: '\(result)'")
    }
}
