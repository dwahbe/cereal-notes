import Foundation
import FoundationModels

/// One action item extracted from a transcript. `owner` is non-nil only when
/// the transcript explicitly names a person — never inferred.
struct ActionItem: Sendable, Equatable {
    let task: String
    let owner: String?
}

struct SummaryResult: Sendable, Equatable {
    let summary: [String]
    let actionItems: [ActionItem]

    static let empty = SummaryResult(summary: [], actionItems: [])

    var isEmpty: Bool { summary.isEmpty && actionItems.isEmpty }
}

protocol TranscriptSummarizer: Sendable {
    /// Returns a best-effort summary. Sections the caller didn't request are
    /// returned empty. On any internal failure, the corresponding section is
    /// empty — never throws.
    func summarize(
        transcript: String,
        generateSummary: Bool,
        generateActionItems: Bool
    ) async -> SummaryResult
}

enum TranscriptSummarizerFactory {
    /// Returns `nil` when Foundation Models is unavailable on this device.
    /// Callers should skip the summary step entirely rather than fall back —
    /// a fabricated summary is worse than none.
    static func make() -> (any TranscriptSummarizer)? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return FoundationModelsSummarizer()
        case .unavailable:
            return nil
        }
    }
}

// MARK: - Generable schemas

@Generable
struct MeetingSummary {
    @Guide(description: "3 to 6 short bullet points capturing the main topics, decisions, and outcomes. Each bullet is one sentence. Plain text — do not start bullets with '-' or '*'.")
    let bullets: [String]
}

@Generable
struct GeneratedActionItem {
    @Guide(description: "What needs to be done, in one short sentence.")
    let task: String
    @Guide(description: "The person responsible if the transcript explicitly names them. Empty string if no owner was named — never infer.")
    let owner: String
}

@Generable
struct GeneratedActionItemList {
    @Guide(description: "Concrete action items mentioned in the transcript. Empty list when nothing was committed to.")
    let items: [GeneratedActionItem]
}

// MARK: - Foundation Models implementation

actor FoundationModelsSummarizer: TranscriptSummarizer {
    private static let summaryInstructions = """
        You write concise meeting summaries from speaker-labeled transcripts. \
        Produce 3 to 6 short bullet points capturing the main topics, decisions, \
        and outcomes. Each bullet is one plain sentence. Do not invent details \
        not present in the transcript. Do not include action items here — those \
        are handled separately.
        """

    private static let actionItemInstructions = """
        You extract concrete action items from speaker-labeled meeting \
        transcripts. An action item is something a participant committed to \
        doing after the meeting. Only include items explicitly stated. For \
        each item, set 'owner' to the participant's name if and only if they \
        were explicitly named as responsible — otherwise leave 'owner' as an \
        empty string. Do not infer owners from context. Return an empty list \
        when nothing was committed to.
        """

    private static let perCallTimeout: Duration = .seconds(15)
    private static let singlePassMaxWords = 2500
    private static let chunkMaxWords = 1500
    private static let maxSummaryBullets = 6
    private static let minBulletCharacters = 3

    private let summarySession: LanguageModelSession
    private let actionSession: LanguageModelSession

    init() {
        summarySession = LanguageModelSession(instructions: Self.summaryInstructions)
        actionSession = LanguageModelSession(instructions: Self.actionItemInstructions)
    }

    func summarize(
        transcript: String,
        generateSummary: Bool,
        generateActionItems: Bool
    ) async -> SummaryResult {
        let body = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return .empty }
        guard generateSummary || generateActionItems else { return .empty }

        let wordCount = SummarizerTextProcessing.wordCount(body)
        if wordCount <= Self.singlePassMaxWords {
            async let summary = generateSummary ? singlePassSummary(body) : []
            async let actions = generateActionItems ? singlePassActions(body) : []
            return SummaryResult(summary: await summary, actionItems: await actions)
        }

        let chunks = SummarizerTextProcessing.speakerTurnChunks(
            body,
            maxWords: Self.chunkMaxWords
        )
        async let summary = generateSummary ? mapReduceSummary(chunks) : []
        async let actions = generateActionItems ? mapReduceActions(chunks) : []
        return SummaryResult(summary: await summary, actionItems: await actions)
    }

    // MARK: Summary

    private func singlePassSummary(_ body: String) async -> [String] {
        let bullets = await requestSummary(body)
        return sanitizeBullets(bullets)
    }

    private func mapReduceSummary(_ chunks: [String]) async -> [String] {
        var intermediate: [String] = []
        for chunk in chunks {
            let bullets = await requestSummary(chunk)
            intermediate.append(contentsOf: bullets)
        }
        guard !intermediate.isEmpty else { return [] }

        let joined = intermediate.map { "- \($0)" }.joined(separator: "\n")
        let reducePrompt = """
            Combine these per-section bullets into one final summary of 3 to 6 \
            bullets capturing the meeting's main topics and decisions. Remove \
            redundancy. Keep each bullet to one sentence.

            \(joined)
            """
        let reduced = await requestSummary(reducePrompt)
        return sanitizeBullets(reduced.isEmpty ? intermediate : reduced)
    }

    private func requestSummary(_ text: String) async -> [String] {
        do {
            return try await withTimeout(Self.perCallTimeout) { [summarySession] in
                let response = try await summarySession.respond(
                    to: text,
                    generating: MeetingSummary.self
                )
                return response.content.bullets
            }
        } catch {
            return []
        }
    }

    // MARK: Action items

    private func singlePassActions(_ body: String) async -> [ActionItem] {
        let raw = await requestActionItems(body)
        return sanitizeActionItems(raw)
    }

    private func mapReduceActions(_ chunks: [String]) async -> [ActionItem] {
        var collected: [GeneratedActionItem] = []
        for chunk in chunks {
            collected.append(contentsOf: await requestActionItems(chunk))
        }
        return sanitizeActionItems(collected)
    }

    private func requestActionItems(_ text: String) async -> [GeneratedActionItem] {
        do {
            return try await withTimeout(Self.perCallTimeout) { [actionSession] in
                let response = try await actionSession.respond(
                    to: text,
                    generating: GeneratedActionItemList.self
                )
                return response.content.items
            }
        } catch {
            return []
        }
    }

    // MARK: Sanitization

    private func sanitizeBullets(_ bullets: [String]) -> [String] {
        let cleaned = bullets
            .map { stripBulletPrefix($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= Self.minBulletCharacters }
        return Array(cleaned.prefix(Self.maxSummaryBullets))
    }

    private func sanitizeActionItems(_ items: [GeneratedActionItem]) -> [ActionItem] {
        var seen = Set<String>()
        var out: [ActionItem] = []
        for item in items {
            let task = stripBulletPrefix(item.task).trimmingCharacters(in: .whitespacesAndNewlines)
            guard task.count >= Self.minBulletCharacters else { continue }
            let key = normalize(task)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let trimmedOwner = item.owner.trimmingCharacters(in: .whitespacesAndNewlines)
            let owner: String? = trimmedOwner.isEmpty ? nil : trimmedOwner
            out.append(ActionItem(task: task, owner: owner))
        }
        return out
    }

    private func stripBulletPrefix(_ s: String) -> String {
        var trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = trimmed.first, first == "-" || first == "*" || first == "•" {
            trimmed.removeFirst()
            trimmed = trimmed.trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    private func normalize(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == " "
        }.map(String.init).joined()
    }
}

// MARK: - Shared text processing

enum SummarizerTextProcessing {
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// Split a markdown transcript on speaker-turn boundaries (`**Speaker** (...):`),
    /// packing turns into chunks up to `maxWords`. Falls back to a single chunk
    /// when no turn markers are found.
    static func speakerTurnChunks(_ text: String, maxWords: Int) -> [String] {
        let turns = splitOnSpeakerTurns(text)
        guard !turns.isEmpty else { return [text] }

        var chunks: [String] = []
        var current: [String] = []
        var currentWords = 0

        for turn in turns {
            let turnWords = wordCount(turn)
            if !current.isEmpty && currentWords + turnWords > maxWords {
                chunks.append(current.joined(separator: "\n\n"))
                current.removeAll(keepingCapacity: true)
                currentWords = 0
            }
            current.append(turn)
            currentWords += turnWords
        }
        if !current.isEmpty {
            chunks.append(current.joined(separator: "\n\n"))
        }
        return chunks
    }

    private static func splitOnSpeakerTurns(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var turns: [[String]] = []
        var current: [String] = []

        for line in lines {
            if line.hasPrefix("**") && current.isEmpty == false && hasSpeakerHeader(line) {
                turns.append(current)
                current = [line]
            } else if line.hasPrefix("**") && current.isEmpty && hasSpeakerHeader(line) {
                current.append(line)
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty {
            turns.append(current)
        }

        return turns
            .map { $0.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func hasSpeakerHeader(_ line: String) -> Bool {
        // `**Speaker** (HH:MM:SS):` heuristic — sufficient to detect turn starts.
        guard line.hasPrefix("**") else { return false }
        guard let closing = line.range(of: "** (") else { return false }
        return line[closing.upperBound...].contains("):")
    }
}

// MARK: - Timeout helper

private struct SummarizerTimeoutError: Error {}

private func withTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw SummarizerTimeoutError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
