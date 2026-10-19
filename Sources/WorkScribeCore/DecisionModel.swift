import Foundation

/// Calibrated CPU decision stage. Implementations never generate note text.
public protocol DecisionModel: Sendable {
    var relevanceThreshold: Double { get }
    var answerabilityThreshold: Double { get }
    func relevance(jot: Note, candidates: [TranscriptChunk]) throws -> [Double]
    func updateRelevance(jot: Note, candidates: [TranscriptChunk]) throws -> [Double]
    func topicRelevance(jot: Note, candidates: [TranscriptChunk]) throws -> [Double]
    func cosines(jot: Note, candidates: [TranscriptChunk]) throws -> [Double]
    func answerability(jot: Note, evidence: [TranscriptChunk]) throws -> Double
}

/// Compact CPU head over existing EmbeddingGemma vectors and inexpensive text/time features.
/// The bundled artifact is trained offline; identity mismatches fail closed.
public struct EmbeddingDecisionModel: DecisionModel {
    public struct Head: Codable, Sendable {
        public var feature_kind: String
        public var mean: [Double]
        public var scale: [Double]
        public var weights: [Double]
        public var bias: Double
        public var temperature: Double
        public func probability(_ features: [Double]) throws -> Double {
            guard feature_kind == "cheap", features.count == weights.count,
                  mean.count == weights.count, scale.count == weights.count,
                  temperature.isFinite, temperature > 0,
                  (features + mean + scale + weights + [bias]).allSatisfy(\.isFinite),
                  scale.allSatisfy({ $0 > 0 }) else { throw Failure.invalidHead }
            let z = (zip(features.indices, weights).reduce(bias) { $0 + (features[$1.0] - mean[$1.0]) / scale[$1.0] * $1.1 }) / temperature
            return z >= 0 ? 1 / (1 + exp(-z)) : exp(z) / (1 + exp(z))
        }
    }
    public struct Artifact: Codable, Sendable {
        public var version: Int
        public var embeddingModel: String
        public var relevanceThreshold: Double
        public var answerabilityThreshold: Double
        public var contextThreshold: Double? = nil
        public var heads: [String: Head]
    }
    public enum Failure: Error { case invalidHead, embeddingIdentity, invalidThreshold }
    public let artifact: Artifact
    public let cache: any RetrievalVectorSource
    private let speakerChanges: [String: Bool]
    private struct Lexicon: Sendable {
        let tokens: Set<String>
        let words: [String]
        private static func initials(_ words: [String]) -> Set<String> {
            var result = Set<String>()
            for i in words.indices {
                for count in 2...4 where i + count <= words.count {
                    result.insert(words[i..<i + count].compactMap(\.first).map(String.init).joined())
                }
            }
            return result
        }
        init(_ text: String) {
            tokens = EmbeddingDecisionModel.tokens(text)
            words = text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        }
        init(merging parts: [Lexicon]) {
            tokens = parts.reduce(into: Set<String>()) { $0.formUnion($1.tokens) }
            words = parts.flatMap(\.words)
        }
        func coverage(_ query: Set<String>) -> Double {
            var initials: Set<String>?
            let hits = query.filter { word in
                if tokens.contains(word) || (word.count >= 3 && tokens.contains(where: { candidate in
                    candidate.hasPrefix(word) || (word.count >= 4 && word.hasSuffix("s") && candidate.hasPrefix(String(word.dropLast())))
                })) { return true }
                guard (2...4).contains(word.count) else { return false }
                // Ordinary words need no phrase-initial table.
                if initials == nil { initials = Self.initials(words) }
                return initials!.contains(word) ||
                    (word.count >= 3 && word.rangeOfCharacter(from: CharacterSet(charactersIn: "aeiou")) == nil && initials!.contains { candidate in
                        candidate.count == word.count && zip(candidate, word).filter { $0 != $1 }.count <= 1
                    })
            }
            return Double(hits.count) / Double(max(1, query.count))
        }
    }

    private let words: [String: Lexicon]
    private let contexts: [String: Lexicon]
    public var relevanceThreshold: Double { artifact.relevanceThreshold }
    public var answerabilityThreshold: Double { artifact.answerabilityThreshold }
    public init(artifact: Artifact, cache: any RetrievalVectorSource, chunks: [TranscriptChunk]) throws {
        guard (1...2).contains(artifact.version), artifact.embeddingModel == cache.modelID else { throw Failure.embeddingIdentity }
        guard [artifact.relevanceThreshold, artifact.answerabilityThreshold].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw Failure.invalidThreshold }
        for (key, count) in [("relevance", 6), ("answerability", 7)] + (artifact.version == 2 ? [("contextual", 8)] : []) {
            guard let head = artifact.heads[key] else { throw Failure.invalidHead }
            _ = try head.probability(Array(repeating: 0, count: count))
        }
        if artifact.version == 2 {
            guard let threshold = artifact.contextThreshold, threshold.isFinite, (0.5...1).contains(threshold) else { throw Failure.invalidThreshold }
        }
        self.artifact = artifact; self.cache = cache
        let ordered = chunks.sorted { $0.start < $1.start }
        let ends = Self.prefixEnds(ordered)
        let words = Dictionary(chunks.map { ($0.id, Lexicon($0.text)) }, uniquingKeysWith: { a, _ in a })
        self.words = words
        self.contexts = Dictionary(ordered.enumerated().map { index, chunk in
            (chunk.id, Lexicon(merging: Self.context(for: chunk, index: index, ordered: ordered, ends: ends).compactMap { words[$0.id] }))
        }, uniquingKeysWith: { a, _ in a })
        self.speakerChanges = Dictionary(ordered.enumerated().map { index, chunk in
            (chunk.id, index > 0 && ordered[index - 1].speaker != chunk.speaker)
        }, uniquingKeysWith: { first, _ in first })
    }
    public init(url: URL, cache: any RetrievalVectorSource, chunks: [TranscriptChunk]) throws {
        try self.init(artifact: JSONDecoder().decode(Artifact.self, from: Data(contentsOf: url)), cache: cache, chunks: chunks)
    }
    private static let stop = Set("a an the is are was were to for of and or in on at it this that we i you with be do does did".split(separator: " ").map(String.init))
    public static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased().components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").inverted).filter { !$0.isEmpty }).subtracting(stop)
    }
    public static func features(jot: Note, chunk: TranscriptChunk, cosine: Double, speakerChanged: Bool) -> [Double] {
        let q = tokens(jot.matchingText), d = tokens(chunk.text)
        let gap = jot.createdAt.map { max(chunk.start - $0, $0 - chunk.end, 0) } ?? 0
        return [cosine, min(gap / 600, 1), speakerChanged ? 1 : 0,
                Double(q.intersection(d).count) / Double(max(1, q.count)),
                Double(q.intersection(d).count) / Double(max(1, q.union(d).count)),
                log1p(Double(chunk.text.split(whereSeparator: \.isWhitespace).count))]
    }
    /// Shorthand is compared with words actually heard: prefixes and initials need no alias dictionary.
    public static func coverage(_ query: String, in text: String) -> Double {
        Lexicon(text).coverage(tokens(query))
    }
    /// A name or question often lives in the preceding turn while the answer spans several chunks.
    public static func context(for chunk: TranscriptChunk, in chunks: [TranscriptChunk]) -> [TranscriptChunk] {
        let ordered = chunks.sorted { $0.start < $1.start }
        return context(for: chunk, index: ordered.firstIndex { $0.id == chunk.id }, ordered: ordered, ends: prefixEnds(ordered))
    }
    private static func prefixEnds(_ chunks: [TranscriptChunk]) -> [Double] {
        var end = -Double.infinity
        return chunks.map { end = max(end, $0.end); return end }
    }
    private static func context(for chunk: TranscriptChunk, index: Int?, ordered: [TranscriptChunk], ends: [Double]) -> [TranscriptChunk] {
        let gap = EngineConstants().answerContext, span = EngineConstants().lookback
        let lower = chunk.start - gap, upper = chunk.end + gap
        var low = 0, high = ordered.count
        while low < high {
            let mid = (low + high) / 2
            if ends[mid] < lower { low = mid + 1 } else { high = mid }
        }
        var first = low
        low = 0; high = ordered.count
        while low < high {
            let mid = (low + high) / 2
            if ordered[mid].start <= upper { low = mid + 1 } else { high = mid }
        }
        var last = low - 1, turn: ClosedRange<Int>?
        if !chunk.speaker.isEmpty, let index {
            var start = index, end = index
            while start > 0 && ordered[start - 1].speaker == chunk.speaker && ordered[start].start - ordered[start - 1].end <= gap && chunk.start - ordered[start - 1].start <= span { start -= 1 }
            while end + 1 < ordered.count && ordered[end + 1].speaker == chunk.speaker && ordered[end + 1].start - ordered[end].end <= gap && ordered[end + 1].end - chunk.end <= span { end += 1 }
            if start > 0 && ordered[start].start - ordered[start - 1].end <= gap && chunk.start - ordered[start - 1].start <= span { start -= 1 }
            turn = start...end; first = min(first, start); last = max(last, end)
        }
        guard first <= last else { return [] }
        return (first...last).compactMap { i in
            let value = ordered[i]
            return turn?.contains(i) == true || (value.start <= upper && value.end >= lower) ? value : nil
        }
    }
    public static func contextualFeatures(jot: Note, chunk: TranscriptChunk, cosine: Double,
                                          speakerChanged: Bool, neighbors: [TranscriptChunk]) -> [Double] {
        let context = Self.context(for: chunk, in: neighbors).map(\.text).joined(separator: " ")
        return features(jot: jot, chunk: chunk, cosine: cosine, speakerChanged: speakerChanged) +
            [coverage(jot.matchingText, in: chunk.text), coverage(jot.matchingText, in: context)]
    }
    private func features(jot: Note, chunks: [TranscriptChunk]) throws -> [[Double]] {
        try cache.require([RetrievalText(jot.matchingText, query: true)] + chunks.map { RetrievalText($0.text, query: false) })
        let q = cache.vector(RetrievalText(jot.matchingText, query: true))!
        let queryTokens = Self.tokens(jot.matchingText)
        return try chunks.map { chunk in
            let d = cache.vector(RetrievalText(chunk.text, query: false))!
            guard q.count == d.count, !q.isEmpty, q.allSatisfy(\.isFinite), d.allSatisfy(\.isFinite) else { throw Failure.embeddingIdentity }
            let words = words[chunk.id] ?? Lexicon(chunk.text)
            let intersection = queryTokens.intersection(words.tokens).count
            let gap = jot.createdAt.map { max(chunk.start - $0, $0 - chunk.end, 0) } ?? 0
            return [Double(VectorMath.dot(q, d)), min(gap / 600, 1), speakerChanges[chunk.id] == true ? 1 : 0,
                    Double(intersection) / Double(max(1, queryTokens.count)),
                    Double(intersection) / Double(max(1, queryTokens.union(words.tokens).count)),
                    log1p(Double(chunk.text.split(whereSeparator: \.isWhitespace).count)),
                    words.coverage(queryTokens), (contexts[chunk.id] ?? words).coverage(queryTokens)]
        }
    }
    public static func bundled(cache: any RetrievalVectorSource, chunks: [TranscriptChunk]) throws -> Self {
        let packaged = Bundle.main.url(forResource: "decision-head", withExtension: "json")
        // A signed app uses Contents/Resources, independently of its original SwiftPM checkout.
        let url = packaged ?? (Bundle.main.bundleURL.pathExtension == "app" ? nil : Bundle.module.url(forResource: "decision-head", withExtension: "json"))
        guard let url else { throw Failure.invalidHead }
        return try Self(url: url, cache: cache, chunks: chunks)
    }
    public func cosines(jot: Note, candidates: [TranscriptChunk]) throws -> [Double] {
        try features(jot: jot, chunks: candidates).map { $0[0] }
    }
    private func score(_ values: [Double]) throws -> Double {
        let baseline = try artifact.heads["relevance"]!.probability(Array(values.prefix(6)))
        guard let context = artifact.heads["contextual"], let threshold = artifact.contextThreshold,
              max(values[6], values[7]) > values[3] + 1e-6 else { return baseline }
        let expanded = try context.probability(values)
        return expanded >= threshold ? max(baseline, expanded) : baseline
    }
    public func relevance(jot: Note, candidates: [TranscriptChunk]) throws -> [Double] {
        try features(jot: jot, chunks: candidates).map(score)
    }
    public func updateRelevance(jot: Note, candidates: [TranscriptChunk]) throws -> [Double] {
        try features(jot: jot, chunks: candidates).map { values in
            // Neighbours can explain an initial answer, but cannot make unrelated new speech an update.
            if values[6] > values[3] + 1e-6 { return try score(values) }
            return try artifact.heads["relevance"]!.probability(Array(values.prefix(6)))
        }
    }
    public func answerability(jot: Note, evidence: [TranscriptChunk]) throws -> Double {
        guard !evidence.isEmpty else { return 0 }
        let f = try features(jot: jot, chunks: evidence), cosine = f.map { $0[0] }.sorted(by: >)
        let union = evidence.reduce(into: Set<String>()) { $0.formUnion(Self.tokens($1.text)) }, q = Self.tokens(jot.matchingText)
        return try artifact.heads["answerability"]!.probability([
            cosine[0], cosine.prefix(3).reduce(0, +) / Double(min(3, cosine.count)), f.map { $0[3] }.max()!,
            Double(q.intersection(union).count) / Double(max(1, q.count)), f.map { $0[4] }.max()!,
            f.map { $0[1] }.min()!, log1p(Double(evidence.count))])
    }
}

public extension DecisionModel {
    func updateRelevance(jot: Note, candidates: [TranscriptChunk]) throws -> [Double] {
        try relevance(jot: jot, candidates: candidates)
    }
    func topicRelevance(jot: Note, candidates: [TranscriptChunk]) throws -> [Double] {
        var query = jot; query.createdAt = nil
        return try relevance(jot: query, candidates: candidates)
    }
    func cosines(jot: Note, candidates: [TranscriptChunk]) throws -> [Double] {
        throw EmbeddingDecisionModel.Failure.embeddingIdentity
    }
}
