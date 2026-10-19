import Foundation
@testable import WorkScribeCore

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
