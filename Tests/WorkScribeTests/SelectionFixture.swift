import Foundation
@testable import WorkScribeCore
@testable import WorkScribe

/// Fixed generator input for parser/apply tests. Retrieval policy is exercised by FindTests.
enum SelectionFixture {
    static func finalPlan(_ meeting: Meeting) throws -> EnrichmentBatch { try plan(meeting, incremental: false) }
    static func plan(_ meeting: Meeting, matcher: any NoteMatcher = LexicalMatcher(), incremental: Bool) throws -> EnrichmentBatch {
        let chunks = Chunker.transcript(meeting)
        var batch = EnrichmentBatch()
        for note in meeting.notes ?? [] where !note.matchingText.isEmpty && note.line.owned != true && note.fromAnswer == nil {
            let scores = try matcher.similarities(notes: [note.matchingText], chunks: chunks.map(\.text)).first ?? []
            let selected = zip(chunks, scores).filter { $0.1 > 0.2 }.map(\.0)
            let refs = selected.map { chunk -> String in
                if let existing = batch.excerpts.first(where: { $0.chunk.id == chunk.id }) { return existing.id }
                let id = "E\(batch.excerpts.count + 1)"; batch.excerpts.append(PromptEvidence(id: id, chunk: chunk)); return id
            }
            batch.targets.append(LineRequest(note: note, refs: refs, fresh: refs, previous: nil))
            batch.chunkRefs[note.id] = selected.map(\.id)
        }
        return batch
    }
}

struct FixtureEmbedder: Embedder {
    let modelID = "fixture", dimension = 2, supportsAudio = false
    func text(_ value: String, role: TextRole) async throws -> [Float] { [1, 0] }
    func audio(_ pcm16k: [Float]) async throws -> [Float] { throw EmbedderError.audioUnsupported }
}
struct FixtureDecision: DecisionModel {
    var relevanceThreshold = 0.042, answerabilityThreshold = 0.5
    var answer = 1.0
    func relevance(jot: Note, candidates: [TranscriptChunk]) throws -> [Double] { candidates.map { _ in 0.9 } }
    func answerability(jot: Note, evidence: [TranscriptChunk]) throws -> Double { answer }
}

// Scheduler fixtures carry outcomes by query ID, just like real generation does.
extension Enrichment {
    static func fixture(plan: EnrichmentBatch, output: String) -> Enrichment {
        var result = Enrichment(plan: plan)
        for (target, bullet) in zip(plan.targets, NoteOutput.parse(output).notes) {
            result.outcomes[target.note.id] = .line(bullet, plan.chunkRefs[target.note.id] ?? [])
            result.bases[target.note.id] = "fixture"
        }
        return result
    }
}
