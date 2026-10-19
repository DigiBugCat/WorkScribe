import Foundation

/// Empty-gold notes do not count as recall failures. Precision is undefined with no selection.
/// Counts and denominators are emitted so micro and macro averages cannot be confused.
public struct RetrievalMetrics: Codable, Equatable, Sendable {
    public var selected: Int
    public var relevant: Int
    public var hits: Int
    public var recall: Double? { relevant > 0 ? Double(hits) / Double(relevant) : nil }
    public var precision: Double? { selected > 0 ? Double(hits) / Double(selected) : nil }
    public var f1: Double? { relevant + selected > 0 ? 2 * Double(hits) / Double(relevant + selected) : nil }
    public var zeroHit: Bool { relevant > 0 && hits == 0 }
    public var falseMatch: Bool
    public init(selected: Set<String>, gold: Set<String>, abstain: Bool) {
        self.selected = selected.count; relevant = gold.count; hits = selected.intersection(gold).count
        // Abstention labels with evidence are answerable for retrieval and exempt from this penalty.
        falseMatch = abstain && gold.isEmpty && !selected.isEmpty
    }
}
