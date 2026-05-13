import Foundation

/// One streaming-ASR utterance, ordered by timestamp then by source side so
/// renderings interleave deterministically when mic + system finalize at the
/// same time.
struct TranscriptEntry: Comparable, Sendable {
    let source: AudioSide
    let speaker: String
    let text: String
    let timestamp: TimeInterval

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.timestamp == rhs.timestamp {
            return lhs.source.sortOrder < rhs.source.sortOrder
        }
        return lhs.timestamp < rhs.timestamp
    }
}

/// Tracks recent system-audio utterances and tells us when an incoming mic
/// utterance is likely an echo of remote speech (e.g., the mic picked up a
/// participant talking through the laptop speakers).
///
/// Two callers — the streaming pipeline (`TranscriptionService`) keeps one
/// long-lived context across the session, and the final high-accuracy render
/// pass builds a fresh one. Both apply the same n-gram containment heuristic
/// from `TranscriptTextProcessing.isLikelyEcho`.
struct EchoSuppressionContext {
    private var systemEntries: [TranscriptEntry] = []
    private var systemWords: [String] = []
    private var systemBigrams: Set<String> = []
    private var systemTrigrams: Set<String> = []

    mutating func reset() {
        systemEntries = []
        systemWords = []
        systemBigrams = []
        systemTrigrams = []
    }

    mutating func recordSystemEntry(
        _ entry: TranscriptEntry,
        lookbackSeconds: TimeInterval,
        maxEntries: Int
    ) {
        systemEntries.append(entry)
        pruneEntries(relativeTo: entry.timestamp, lookbackSeconds: lookbackSeconds)
        if systemEntries.count > maxEntries {
            systemEntries.removeFirst(systemEntries.count - maxEntries)
        }
        rebuildCache()
    }

    mutating func shouldSuppressMicEntry(
        _ entry: TranscriptEntry,
        lookbackSeconds: TimeInterval
    ) -> Bool {
        if pruneEntries(relativeTo: entry.timestamp, lookbackSeconds: lookbackSeconds) {
            rebuildCache()
        }
        return TranscriptTextProcessing.isLikelyEcho(
            micText: entry.text,
            systemWords: systemWords,
            systemBigrams: systemBigrams,
            systemTrigrams: systemTrigrams
        )
    }

    @discardableResult
    private mutating func pruneEntries(
        relativeTo timestamp: TimeInterval,
        lookbackSeconds: TimeInterval
    ) -> Bool {
        let cutoff = timestamp - lookbackSeconds
        let originalCount = systemEntries.count
        systemEntries.removeAll { $0.timestamp < cutoff }
        return systemEntries.count != originalCount
    }

    private mutating func rebuildCache() {
        systemWords = systemEntries.flatMap { TranscriptTextProcessing.normalizedWords($0.text) }
        systemBigrams = TranscriptTextProcessing.shingles(from: systemWords, size: 2)
        systemTrigrams = TranscriptTextProcessing.shingles(from: systemWords, size: 3)
    }
}
