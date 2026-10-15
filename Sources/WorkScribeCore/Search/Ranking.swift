// Ported from DigUp (MIT, © 2026 Abdur Rahim), Sources/DigUpKit/Searcher.swift @ f9b8106 (`meaning`,
// `modalityMeans`, the coverage-bonus fusion in `search`, `strongCount`). See Resources/licenses/digup.
// Changes: ranks moments (chunks) rather than files, a raw-cosine gate while the index is too small for z-scores,
// a per-source cap instead of one hit per file.
import Foundation

public enum Modality: String, Sendable, CaseIterable {
    case text, audio, image, none
}

/// Hybrid ranking: meaning (EmbeddingGemma cosines put on one scale per query) fused with words (FTS5 coverage).
///
/// DigUp's measurements, kept as the starting point: this fusion beat reciprocal-rank fusion on its evals (R@1 0.88 vs
/// 0.73 synthetic, 0.86 vs 0.82 real), and the 0.5 "strong" ratio cut results from 26 to 6 per query without folding
/// an expected answer. They need re-tuning on real meetings.
public struct Ranking: Sendable {
    /// Meaning matches must stand this many deviations above the query's average.
    public var zGate = 2.0
    /// How much finding the query's words counts against meaning.
    public var wordWeight = 2.0
    /// Below this many vectors, z-scores mean little; meaning matches are gated on the raw cosine instead.
    public var minimumForZ = 200
    /// The raw-cosine gate for small indexes. On the Core ML smoke test (2026-10-13) EmbeddingGemma 2 put matching
    /// query/passage pairs at 0.73–0.87 and non-matching ones at 0.56–0.65; tune on real meetings.
    public var cosineFloor: Float = 0.68
    public init() {}

    public struct Candidate: Sendable {
        public var z: Double?
        public var cosine: Float?
        public var coverage: Double
        public var kindHinted: Bool
    }

    public enum Match: String, Sendable { case meaning, words, both }

    /// This query's meaning scores: each cosine minus the average of its modality, in standard deviations of all of
    /// them together (DigUp found per-modality deviations inflated the narrow modalities).
    public static func meaning(_ scores: [Float], _ modality: [Modality]) -> [Double] {
        let means = modalityMeans(scores, modality)
        let centered = zip(scores, modality).map { Double($0) - means[$1, default: 0] }
        let mean = centered.reduce(0, +) / Double(max(centered.count, 1))
        let squares = centered.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        let deviation = max((squares / Double(max(centered.count, 1))).squareRoot(), 0.02)
        return centered.map { ($0 - mean) / deviation }
    }

    /// The average score of each modality for this query. Small groups (< 20 vectors) take the average of all.
    public static func modalityMeans(_ scores: [Float], _ modality: [Modality]) -> [Modality: Double] {
        var sum: [Modality: Double] = [:], count: [Modality: Int] = [:]
        for row in scores.indices {
            sum[modality[row], default: 0] += Double(scores[row])
            count[modality[row], default: 0] += 1
        }
        let all = sum.values.reduce(0, +) / Double(max(count.values.reduce(0, +), 1))
        var out: [Modality: Double] = [:]
        for modality in Modality.allCases {
            if let n = count[modality], n >= 20 { out[modality] = sum[modality]! / Double(n) } else { out[modality] = all }
        }
        return out
    }

    /// Whether the meaning side of a candidate stands out, on this index's scale.
    public func meaningPasses(_ candidate: Candidate, vectorCount: Int) -> Bool {
        guard let z = candidate.z else { return false }
        if vectorCount < minimumForZ { return (candidate.cosine ?? -1) >= cosineFloor }
        return z >= zGate
    }

    /// A candidate qualifies by standing out in meaning or by containing at least half of the query's words.
    /// Score: meaning z + a bonus growing with word coverage, + 1 for the kind the query asks for. Lookups (codes,
    /// IDs) weigh words double and meaning half.
    public func score(_ candidate: Candidate, vectorCount: Int, lookup: Bool) -> (score: Double, match: Match)? {
        let meaning = meaningPasses(candidate, vectorCount: vectorCount)
        let words = candidate.coverage >= 0.5
        guard meaning || words else { return nil }
        let (meaningWeight, wordsWeight) = lookup ? (0.5, wordWeight * 2) : (1, wordWeight)
        // In the small regime z can still be negative-ish for a cosine that passed; the cosine stands in.
        let z = vectorCount < minimumForZ ? max(candidate.z ?? 0, Double(candidate.cosine ?? 0) * 4) : (candidate.z ?? 0)
        var score = meaningWeight * max(z, 0) + wordsWeight * pow(candidate.coverage, 1.5)
        if candidate.kindHinted { score += 1 }
        return (score, meaning && candidate.coverage > 0 ? .both : meaning ? .meaning : .words)
    }

    /// How many of `scores` (best first) are strong: at least `ratio` × the top one. The rest trail far behind.
    public static func strongCount(_ scores: [Double], ratio: Double = 0.5) -> Int {
        guard let top = scores.first, top > 0 else { return scores.count }
        return scores.prefix { $0 >= top * ratio }.count
    }
}
