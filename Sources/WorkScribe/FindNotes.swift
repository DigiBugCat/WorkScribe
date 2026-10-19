import Foundation
import WorkScribeCore

/// Bridges the shared index to the old generator while the line lifecycle is rebuilt.
struct FindNotes {
    let constants: EngineConstants
    let index: SearchIndex
    let vectors: IndexVectors
    let decision: any DecisionModel
    let chunks: [Chunk]

    func select(_ meeting: Meeting, incremental: Bool,
                observe: (@Sendable (String, EnrichmentBatch) -> Void)?) throws -> EnrichmentBatch {
        var batch = EnrichmentBatch(), candidates = EnrichmentBatch(), retained = EnrichmentBatch()
        let open = (meeting.notes ?? []).filter { $0.line.owned != true && $0.fromAnswer == nil && $0.surface == nil && !$0.isImage && !$0.matchingText.isEmpty }
        let decision = try BatchDecision(base: decision, notes: open, chunks: chunks.map(\.transcript))
        for note in meeting.notes ?? [] where note.line.owned != true && note.fromAnswer == nil && note.surface == nil {
            if note.isImage || note.matchingText.isEmpty {
                if !note.imageEvidence.isEmpty { batch.targets.append(LineRequest(note: note, refs: [], fresh: [], previous: note.line.text)) }
                continue
            }
            let source = SourceID(.meeting, meeting.id)
            var watch = try index.watch(source: source, query: note.id)
            let found = try Find(constants: constants).run(note: note, meeting: chunks, closed: meeting.status != "recording", decision: decision, watch: &watch, competitors: open, queryVector: vectors.vector(RetrievalText(note.matchingText, query: true))) { rung in
                guard rung == .vault, let vector = vectors.vector(RetrievalText(note.matchingText, query: true)) else { return [] }
                return try index.candidates(QueryVector(text: note.matchingText, vector: vector, model: vectors.modelID),
                                            scope: .vault(excluding: Set([SourceID(.meeting, meeting.id)] + [meeting.document?.path, meeting.vaultPath].compactMap { $0 }.map { SourceID(.vault, $0) })), limit: 72)
            }
            batch.findings[note.id] = Finding(rung: found.rung, holding: found.holding, answerable: found.answerable, candidates: found.candidates.count)
            candidates.findings = batch.findings
            // The retained envelope uses globally unique IDs; each query still owns a stable E1... sequence.
            func ids(_ evidence: [Evidence], into target: inout EnrichmentBatch) -> [String] {
                evidence.map { e in
                    let id = note.id + ":" + watch.identifier(e.chunk.id)
                    if !target.excerpts.contains(where: { $0.id == id }) { target.excerpts.append(PromptEvidence(id: id, chunk: e.chunk.transcript)) }
                    return id
                }
            }
            let allRefs = ids(found.candidates, into: &candidates)
            candidates.targets.append(LineRequest(note: note, refs: allRefs, fresh: allRefs, previous: note.line.text))
            let keptRefs = ids(found.retained, into: &retained)
            retained.targets.append(LineRequest(note: note, refs: keptRefs, fresh: [], previous: note.line.text))
            let groups = EvidencePack.groups(found, note: note, chunks: Array(Dictionary((found.retained + found.evidence).map { ($0.chunk.id, $0.chunk) }, uniquingKeysWith: { a, _ in a }).values).sorted { $0.seq < $1.seq }, constants: constants)
            let packed = groups.flatMap { $0 }
            let backgroundEvidence = (found.rung == .vault || found.rung == .linked) ? packed : found.background
            let background = backgroundEvidence.map { BackgroundSnippet(id: $0.chunk.source.ref, title: $0.chunk.context ?? "Note", text: $0.chunk.text ?? "", cosine: Float($0.relevance)) }
            let refs = found.answerable ? ids(packed, into: &batch) : []
            let old = Set(note.line.attemptedEvidence ?? note.line.evidence ?? [])
            let fresh = packed.filter { !old.contains($0.chunk.id) }
            let freshRefs = Set(fresh.map { note.id + ":" + watch.identifier($0.chunk.id) })
            batch.chunkRefs[note.id] = found.answerable ? packed.map { $0.chunk.id } : []
            let update: Bool
            if found.rung == .vault || found.rung == .linked {
                // Untimed passages already passed their cosine gate; the timed head has no vault vectors.
                update = fresh.contains { $0.relevance >= constants.untimed }
            } else {
                update = try decision.updateRelevance(jot: note, candidates: fresh.map { $0.chunk.transcript }).contains { $0 >= constants.stop }
            }
            if (note.lineNeedsEvidence && note.line.basis == nil && found.answerable) || update {
                batch.targets.append(LineRequest(note: note, refs: refs, fresh: refs.filter { freshRefs.contains($0) }, previous: note.line.text,
                    background: background, backgroundOnly: found.rung == .vault || found.rung == .linked, groups: groups.map { $0.map { note.id + ":" + watch.identifier($0.chunk.id) } }))
            }
            for i in batch.targets.indices where batch.targets[i].note.id == note.id {
                batch.targets[i].note.line.seenThrough = watch.seenThrough
            }
            try index.saveWatch(watch, source: source, query: note.id)
        }
        observe?("candidates", candidates)
        retained.findings = batch.findings
        observe?("kept", retained)
        observe?("selected", batch)
        try EvidenceBudget.apply(&batch, constants: constants)
        for i in batch.targets.indices where constants.gateAnswerability && batch.targets[i].previous == nil && !batch.targets[i].backgroundOnly && !batch.targets[i].refs.isEmpty {
            let selected = Set(batch.chunkRefs[batch.targets[i].note.id] ?? [])
            let score = try decision.answerability(jot: batch.targets[i].note, evidence: chunks.filter { selected.contains($0.id) }.map(\.transcript))
            guard score.isFinite, (0...1).contains(score) else { throw EmbeddingDecisionModel.Failure.invalidHead }
            if score < constants.answerable {
                batch.targets[i].refs = []; batch.targets[i].fresh = []
                batch.chunkRefs[batch.targets[i].note.id] = []
                batch.findings[batch.targets[i].note.id]?.answerable = false
            }
        }
        observe?("budgeted", batch)
        return batch
    }
}

/// Each open jot is scored once per vectorized snapshot, including competition for shared passages.
private struct BatchDecision: DecisionModel {
    let base: any DecisionModel
    let scores: [String: [String: Double]]
    let topics: [String: [String: Double]]
    let referenceTimes: [String: Double]
    var relevanceThreshold: Double { base.relevanceThreshold }
    var answerabilityThreshold: Double { base.answerabilityThreshold }
    init(base: any DecisionModel, notes: [Note], chunks: [TranscriptChunk]) throws {
        self.base = base
        var scores: [String: [String: Double]] = [:], topics: [String: [String: Double]] = [:]
        for note in notes {
            let values = try base.relevance(jot: note, candidates: chunks)
            guard values.count == chunks.count else { throw EmbeddingDecisionModel.Failure.invalidHead }
            let topical = try base.topicRelevance(jot: note, candidates: chunks)
            guard topical.count == chunks.count else { throw EmbeddingDecisionModel.Failure.invalidHead }
            topics[note.id] = Dictionary(zip(chunks.map(\.id), topical), uniquingKeysWith: { a, _ in a })
            scores[note.id] = Dictionary(zip(chunks.map(\.id), values), uniquingKeysWith: { a, _ in a })
        }
        self.scores = scores; self.topics = topics
        self.referenceTimes = Dictionary(notes.compactMap { note in note.createdAt.map { (note.id, $0) } }, uniquingKeysWith: { a, _ in a })
    }
    func relevance(jot: Note, candidates: [TranscriptChunk]) throws -> [Double] {
        guard jot.createdAt == referenceTimes[jot.id], let scores = scores[jot.id], candidates.allSatisfy({ scores[$0.id] != nil }) else {
            return try base.relevance(jot: jot, candidates: candidates)
        }
        return candidates.map { scores[$0.id]! }
    }
    func updateRelevance(jot: Note, candidates: [TranscriptChunk]) throws -> [Double] {
        try base.updateRelevance(jot: jot, candidates: candidates)
    }
    func topicRelevance(jot: Note, candidates: [TranscriptChunk]) throws -> [Double] {
        guard let values = topics[jot.id], candidates.allSatisfy({ values[$0.id] != nil }) else {
            return try base.topicRelevance(jot: jot, candidates: candidates)
        }
        return candidates.map { values[$0.id]! }
    }
    func cosines(jot: Note, candidates: [TranscriptChunk]) throws -> [Double] { try base.cosines(jot: jot, candidates: candidates) }
    func answerability(jot: Note, evidence: [TranscriptChunk]) throws -> Double { try base.answerability(jot: jot, evidence: evidence) }
}
