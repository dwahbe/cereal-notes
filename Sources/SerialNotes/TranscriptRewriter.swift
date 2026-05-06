import Foundation
import FoundationModels

protocol TranscriptRewriter: Sendable {
    /// Rewrite an ASR utterance with restored punctuation + capitalization.
    /// Never throws — implementations must fall back internally so callers
    /// always get usable text.
    func rewrite(_ text: String) async -> String
}

extension TranscriptRewriter where Self == HeuristicRewriter {
    static var heuristic: HeuristicRewriter { HeuristicRewriter() }
}

enum TranscriptRewriterFactory {
    /// Pick the best available rewriter. Falls back to a heuristic if Foundation
    /// Models is not ready on this device (Apple Intelligence off, unsupported
    /// hardware, model still downloading, etc.).
    static func make() -> any TranscriptRewriter {
        switch SystemLanguageModel.default.availability {
        case .available:
            return FoundationModelsRewriter()
        case .unavailable:
            return HeuristicRewriter()
        }
    }
}

/// Deterministic fallback. Capitalizes the first character and appends a period
/// when the utterance doesn't already end with sentence-terminating punctuation.
struct HeuristicRewriter: TranscriptRewriter {
    func rewrite(_ text: String) async -> String {
        applyHeuristic(text)
    }
}

private func applyHeuristic(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return trimmed }

    var out = trimmed
    if let first = out.first, first.isLowercase {
        out = first.uppercased() + out.dropFirst()
    }
    if let last = out.last, !"!?.".contains(last) {
        out.append(".")
    }
    return out
}

/// Rewrites ASR text using Apple's on-device Foundation Models (macOS 26+).
/// Guards against hallucination by comparing the letter/digit sequence of the
/// rewritten text to the input; on mismatch it returns the heuristic output.
actor FoundationModelsRewriter: TranscriptRewriter {
    private static let instructions = """
        You restore punctuation and capitalization to speech-to-text output. \
        Input is lowercase English with no punctuation. Return the exact same \
        words in the same order, adding only commas, periods, question marks, \
        and apostrophes, and capitalizing sentence starts and proper nouns. \
        Never add, remove, reorder, translate, or change any word.
        """

    private static let timeout: Duration = .seconds(2)

    private let session: LanguageModelSession

    init() {
        session = LanguageModelSession(instructions: Self.instructions)
    }

    /// Nudge the model to load so the first real utterance doesn't eat the cold-start.
    func prewarm() async {
        _ = await rewrite("hello")
    }

    func rewrite(_ text: String) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        do {
            let rewritten = try await withTimeout(Self.timeout) { [session] in
                let response = try await session.respond(
                    to: trimmed,
                    generating: PunctuatedUtterance.self
                )
                return response.content.text
            }
            if matchesWords(original: trimmed, rewritten: rewritten) {
                return rewritten.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return applyHeuristic(trimmed)
        } catch {
            return applyHeuristic(trimmed)
        }
    }
}

@Generable
struct PunctuatedUtterance {
    @Guide(description: "The same utterance with sentence-case capitalization and punctuation. Do not change any words.")
    let text: String
}

/// Compare letter/digit sequences (case-insensitive). True iff the rewrite only
/// added punctuation/whitespace/capitalization — any word-level change fails.
private func matchesWords(original: String, rewritten: String) -> Bool {
    func normalize(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
        }.map(String.init).joined()
    }
    return normalize(original) == normalize(rewritten)
}

private struct TimeoutError: Error {}

private func withTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
