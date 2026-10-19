import Foundation

public enum Rung: String, Codable, Sendable { case moment, meeting, linked, vault }
public struct Evidence: Sendable {
    public var chunk: Chunk
    public var relevance: Double
    public var rung: Rung
    public var fresh: Bool
}
public struct FindResult: Sendable {
    public var rung: Rung?
    public var evidence: [Evidence]
    public var candidates: [Evidence]
    public var holding: Bool
    public var answerable: Bool
    public var background: [Evidence] = []
    public var retained: [Evidence] = []
}

/// Per-query state survives process restart and is removed with its source's purge fence.
public struct Watch: Codable, Equatable, Sendable {
    public var text = ""
    public var seenThrough: Int64 = 0
    public var evidenceIDs: [String: String] = [:]
    public var nextID = 1
    public var supporting: [String]?
    public init() {}
    public mutating func identifier(_ chunk: String) -> String {
        if let id = evidenceIDs[chunk] { return id }
        let id = "E\(nextID)"; nextID += 1; evidenceIDs[chunk] = id
        return id
    }
}

/// Timed candidates are scored exhaustively; the vault is not even read until the timed ladder fails.
public struct Find: Sendable {
    public let constants: EngineConstants
    public init(constants: EngineConstants = EngineConstants()) { self.constants = constants }
    public func run(note: Note, meeting: [Chunk], closed: Bool, decision: any DecisionModel,
                    watch: inout Watch, competitors: [Note] = [], queryVector: [Float]? = nil, untimed: (Rung) throws -> [Chunk]) throws -> FindResult {
        if watch.text != note.matchingText {
            watch.text = note.matchingText
            watch.seenThrough = 0
            watch.supporting = []
        }
        let available = meeting.filter { $0.vector != nil && $0.modality == .text }
        let previous = watch.seenThrough
        defer { watch.seenThrough = max(previous, available.map(\.seq).max() ?? 0) }
        let scores = try decision.relevance(jot: note, candidates: available.map(\.transcript))
        guard scores.count == available.count, scores.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw EmbeddingDecisionModel.Failure.invalidHead }
        let observations = zip(available, scores).map { Evidence(chunk: $0, relevance: $1, rung: .meeting, fresh: $0.seq > previous) }
        let others = competitors.filter { $0.id != note.id }
        let topicScores = others.isEmpty ? scores : try decision.topicRelevance(jot: note, candidates: available.map(\.transcript))
        guard topicScores.count == available.count, topicScores.allSatisfy(\.isFinite) else { throw EmbeddingDecisionModel.Failure.invalidHead }
        var excluded = Set<String>()
        for other in others {
            let competing = try decision.topicRelevance(jot: other, candidates: available.map(\.transcript))
            guard competing.count == scores.count, competing.allSatisfy(\.isFinite) else { throw EmbeddingDecisionModel.Failure.invalidHead }
            for (i, score) in competing.enumerated() where score >= constants.stop && topicScores[i] < constants.stop {
                excluded.insert(available[i].id)
            }
        }
        let retained = observations.filter { $0.relevance >= constants.keep && !excluded.contains($0.chunk.id) }
        let byID = Dictionary(observations.map { ($0.chunk.id, $0.relevance) }, uniquingKeysWith: { a, _ in a })
        func untimedEvidence(_ rung: Rung) throws -> [Evidence] {
            let candidates = try untimed(rung).filter { $0.vector != nil && $0.modality == .text }
            if let q = queryVector {
                guard candidates.allSatisfy({ $0.vector?.count == q.count }) else { throw EmbeddingDecisionModel.Failure.embeddingIdentity }
            }
            let scores = try queryVector.map { q in candidates.map { Double(VectorMath.dot(q, $0.vector!)) } } ?? decision.cosines(jot: note, candidates: candidates.map(\.transcript))
            guard scores.count == candidates.count, scores.allSatisfy(\.isFinite) else { throw EmbeddingDecisionModel.Failure.invalidHead }
            return zip(candidates, scores).filter { $0.1 >= constants.untimed }.map { Evidence(chunk: $0, relevance: $1, rung: rung, fresh: $0.seq > previous) }
        }
        func finish(_ value: FindResult) throws -> FindResult {
            var value = value
            value.retained = retained
            if constants.backgroundAlways, value.rung == .moment || value.rung == .meeting {
                value.background = try untimedEvidence(.vault)
            }
            let windowClosed = closed || note.createdAt.map { at in meeting.contains { ($0.end ?? 0) > at + constants.lookahead } } == true
            if note.line.text != nil || (previous > 0 && windowClosed) {
                let selected = Set(value.evidence.map { $0.chunk.id })
                let carried = Set(watch.supporting ?? [])
                let unseen = available.filter { ($0.seq > previous || carried.contains($0.id)) && !selected.contains($0.id) }
                // A rejected first response must still see later answers, even after its original moment succeeded.
                var scores = try decision.relevance(jot: note, candidates: unseen.map(\.transcript))
                if note.line.text != nil {
                    let updates = try decision.updateRelevance(jot: note, candidates: unseen.map(\.transcript))
                    guard updates.count == scores.count, updates.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw EmbeddingDecisionModel.Failure.invalidHead }
                    scores = unseen.indices.map { carried.contains(unseen[$0].id) ? scores[$0] : updates[$0] }
                }
                if constants.topicGap, let latest = available.filter({ (note.line.evidence ?? []).contains($0.id) }).compactMap(\.end).max() {
                    var query = note; query.createdAt = latest
                    let following = try decision.relevance(jot: query, candidates: unseen.map(\.transcript))
                    guard following.count == scores.count else { throw EmbeddingDecisionModel.Failure.invalidHead }
                    scores = zip(scores, following).map { max($0, $1) }
                }
                guard scores.count == unseen.count, scores.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw EmbeddingDecisionModel.Failure.invalidHead }
                let fresh = zip(unseen, scores).filter { $0.1 >= constants.stop && !excluded.contains($0.0.id) }.map { Evidence(chunk: $0, relevance: $1, rung: .meeting, fresh: $0.seq > previous) }
                watch.supporting = fresh.map { $0.chunk.id }
                value.evidence += fresh
                value.evidence.sort { $0.relevance == $1.relevance ? $0.chunk.seq < $1.chunk.seq : $0.relevance > $1.relevance }
            }
            return value
        }
        func timed(_ chunks: [Chunk], rung: Rung) throws -> FindResult? {
            var query = note
            if constants.topicGap, let latest = available.filter({ (note.line.evidence ?? []).contains($0.id) }).compactMap(\.end).max(),
               let typed = note.createdAt {
                // Evaluate both reference points; never approximate the minimum distance with the latest time alone.
                let typedScores = try decision.relevance(jot: query, candidates: chunks.map(\.transcript))
                query.createdAt = latest
                let latestScores = try decision.relevance(jot: query, candidates: chunks.map(\.transcript))
                query.createdAt = typed
                return try select(chunks, scores: zip(typedScores, latestScores).map { max($0, $1) }, rung: rung)
            }
            return try select(chunks, scores: chunks.map { byID[$0.id] ?? 0 }, rung: rung)
        }
        func select(_ chunks: [Chunk], scores: [Double], rung: Rung) throws -> FindResult? {
            guard scores.count == chunks.count, scores.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw EmbeddingDecisionModel.Failure.invalidHead }
            let evidence = zip(chunks, scores).map { Evidence(chunk: $0, relevance: $1, rung: rung, fresh: $0.seq > previous) }
            guard evidence.contains(where: { $0.relevance >= constants.stop && !excluded.contains($0.chunk.id) }) else { return nil }
            let kept = evidence.filter { $0.relevance >= constants.keep && !excluded.contains($0.chunk.id) }.sorted { $0.relevance == $1.relevance ? $0.chunk.seq < $1.chunk.seq : $0.relevance > $1.relevance }
            let probability = try decision.answerability(jot: note, evidence: kept.map { $0.chunk.transcript })
            guard probability.isFinite, (0...1).contains(probability) else { throw EmbeddingDecisionModel.Failure.invalidHead }
            return FindResult(rung: rung, evidence: kept, candidates: observations, holding: false,
                              answerable: !constants.gateAnswerability || probability >= constants.answerable)
        }
        if let at = note.createdAt {
            let moment = available.filter { ($0.start ?? .infinity) <= at + constants.lookahead && ($0.end ?? -.infinity) >= at - constants.lookback }
            if let result = try timed(moment, rung: .moment) { return try finish(result) }
            let windowClosed = closed || meeting.contains { ($0.end ?? 0) > at + constants.lookahead }
            if !windowClosed { return try finish(FindResult(evidence: [], candidates: observations, holding: true, answerable: false)) }
            if let result = try timed(available, rung: .meeting) { return try finish(result) }
        } else if !closed {
            if let result = try timed(available, rung: .meeting) { return try finish(result) }
        }
        for rung in note.createdAt == nil ? [Rung.linked, .vault] : [.vault] {
            let kept = try untimedEvidence(rung)
            if !kept.isEmpty { return try finish(FindResult(rung: rung, evidence: kept.sorted { $0.relevance > $1.relevance }, candidates: observations, holding: false, answerable: true)) }
        }
        return try finish(FindResult(evidence: [], candidates: observations, holding: false, answerable: false))
    }
}

extension Chunk {
    public var transcript: TranscriptChunk {
        TranscriptChunk(id: id, segmentID: segmentIDs.first ?? anchor, speaker: speakers.joined(separator: ", "),
                        start: start ?? 0, end: end ?? 0, text: text ?? "", segmentIDs: segmentIDs.isEmpty ? [id] : segmentIDs)
    }
}

/// Seeds choose the rung; retained neighbors supply the question or answer context across its edge.
public enum EvidencePack {
    public static func groups(_ found: FindResult, note: Note, chunks: [Chunk], constants: EngineConstants) -> [[Evidence]] {
        let question = note.shorthand.hasSuffix("?") || ["what", "when", "where", "who", "why", "how"].contains(note.shorthand.lowercased().split(separator: " ").first.map(String.init) ?? "")
        let allowed = Dictionary((found.retained + found.evidence).map { ($0.chunk.id, $0) }, uniquingKeysWith: { a, _ in a })
        var used = Set<String>()
        return found.evidence.compactMap { seed in
            let group = chunks.compactMap { chunk -> Evidence? in
                guard let scored = allowed[chunk.id], !used.contains(chunk.id) else { return nil }
                let samePassage = chunk.source == seed.chunk.source && chunk.anchor == seed.chunk.anchor
                let near = chunk.source == seed.chunk.source && chunk.start != nil && chunk.end != nil && seed.chunk.start != nil && seed.chunk.end != nil &&
                    chunk.start! <= seed.chunk.end! + (question ? constants.answerContext : constants.neighbor) && chunk.end! >= seed.chunk.start! - constants.neighbor
                return chunk.id == seed.chunk.id || samePassage || near ? scored : nil
            }
            guard !group.isEmpty else { return nil }
            used.formUnion(group.map { $0.chunk.id })
            return group.sorted { ($0.chunk.start ?? 0) < ($1.chunk.start ?? 0) }
        }
    }
}
