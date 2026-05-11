import Foundation

@MainActor @Observable
final class SummarySettings {
    private static let summaryKey = "summary.generateSummary"
    private static let actionItemsKey = "summary.generateActionItems"

    var generateSummary: Bool {
        didSet {
            UserDefaults.standard.set(generateSummary, forKey: Self.summaryKey)
        }
    }

    var generateActionItems: Bool {
        didSet {
            UserDefaults.standard.set(generateActionItems, forKey: Self.actionItemsKey)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        self.generateSummary = defaults.object(forKey: Self.summaryKey) as? Bool ?? true
        self.generateActionItems = defaults.object(forKey: Self.actionItemsKey) as? Bool ?? true
    }

    /// Sendable snapshot for handing flags across actor boundaries.
    struct Snapshot: Sendable {
        let generateSummary: Bool
        let generateActionItems: Bool

        static let disabled = Snapshot(generateSummary: false, generateActionItems: false)
    }

    func snapshot() -> Snapshot {
        Snapshot(generateSummary: generateSummary, generateActionItems: generateActionItems)
    }
}
