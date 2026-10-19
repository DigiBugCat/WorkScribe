import XCTest
@testable import WorkScribeCore

final class FindTests: XCTestCase {
    struct Head: DecisionModel {
        var relevanceThreshold = 0.042, answerabilityThreshold = 0.5
        var scores: [String: Double] = [:]
        var answer = 1.0
        func relevance(jot: Note, candidates: [TranscriptChunk]) throws -> [Double] { candidates.map { scores[$0.id] ?? 0 } }
        func answerability(jot: Note, evidence: [TranscriptChunk]) throws -> Double { answer }
        func cosines(jot: Note, candidates: [TranscriptChunk]) throws -> [Double] { candidates.map { scores[$0.id] ?? 0 } }
    }
    func chunk(_ id: String, _ start: Double, _ end: Double, seq: Int64 = 1, vector: Bool = true) -> Chunk {
        var c = Chunk(kind: .meetingSegment, modality: .text, start: start, end: end, segmentIDs: [id], speakers: ["A"], text: "A concrete supported fact.", vector: vector ? [1, 0] : nil)
        c.id = id; c.seq = seq; c.source = SourceID(.meeting, "m"); c.anchor = id
        return c
    }
    struct CompetitionHead: DecisionModel {
        var relevanceThreshold = 0.042, answerabilityThreshold = 0.5
        func relevance(jot: Note, candidates: [TranscriptChunk]) throws -> [Double] {
            candidates.map { jot.text == "own" ? ($0.id == "shared" ? 0.6 : 0.1) : 0.9 }
        }
        func answerability(jot: Note, evidence: [TranscriptChunk]) throws -> Double { 1 }
    }
    func testSharedEvidenceSurvivesWhileCompetitorOnlyEvidenceIsExcluded() throws {
        var watch = Watch()
        let own = Note(text: "own", createdAt: 5), other = Note(text: "other", createdAt: 5)
        let result = try Find().run(note: own, meeting: [chunk("shared", 0, 5), chunk("other", 1, 4)], closed: false,
            decision: CompetitionHead(), watch: &watch, competitors: [own, other]) { _ in [] }
        XCTAssertEqual(result.evidence.map { $0.chunk.id }, ["shared"])
        XCTAssertEqual(result.retained.map { $0.chunk.id }, ["shared"])
    }
    func testMomentWinsWithoutReadingWiderScopes() throws {
        var watch = Watch(); let note = Note(text: "price?", createdAt: 100)
        let value = try Find().run(note: note, meeting: [chunk("old", 0, 1), chunk("now", 95, 101)], closed: false,
                                  decision: Head(scores: ["old": 0.99, "now": 0.5]), watch: &watch) { _ in XCTFail("vault was read"); return [] }
        XCTAssertEqual(value.rung, .moment); XCTAssertEqual(value.evidence.map { $0.chunk.id }, ["now"])
    }
    func testSpeechClosesWindowAndWideningNeverLowersBar() throws {
        var watch = Watch(); let note = Note(text: "price?", createdAt: 100)
        let early = chunk("old", 0, 1)
        let held = try Find().run(note: note, meeting: [early, chunk("edge", 129, 130)], closed: false,
                                 decision: Head(scores: ["old": 0.9]), watch: &watch) { _ in XCTFail(); return [] }
        XCTAssertTrue(held.holding)
        let wide = try Find().run(note: note, meeting: [early, chunk("closed", 130, 131)], closed: false,
                                 decision: Head(scores: ["old": 0.9]), watch: &watch) { _ in XCTFail(); return [] }
        XCTAssertEqual(wide.rung, .meeting)
        let quiet = try Find().run(note: note, meeting: [early], closed: true,
                                  decision: Head(scores: ["old": 0.499]), watch: &watch) { _ in [] }
        XCTAssertNil(quiet.rung); XCTAssertFalse(quiet.answerable)
    }
    func testAnswerabilityCannotCauseCrossTopicWidening() throws {
        var watch = Watch()
        let result = try Find().run(note: Note(text: "price", createdAt: 5), meeting: [chunk("a", 0, 5)], closed: true,
                                   decision: Head(scores: ["a": 0.9], answer: 0.1), watch: &watch) { _ in XCTFail(); return [] }
        XCTAssertEqual(result.rung, .moment); XCTAssertFalse(result.answerable)
    }
    func testMissingVectorsAreNotHeardAndInvalidScoresThrow() throws {
        var watch = Watch()
        let missing = chunk("a", 0, 5, vector: false)
        let result = try Find().run(note: Note(text: "price", createdAt: 5), meeting: [missing], closed: false,
                                   decision: Head(scores: ["a": 1]), watch: &watch) { _ in [] }
        XCTAssertTrue(result.evidence.isEmpty); XCTAssertEqual(watch.seenThrough, 0)
        XCTAssertThrowsError(try Find().run(note: Note(text: "price", createdAt: 5), meeting: [chunk("a", 0, 5)], closed: false,
                                            decision: Head(scores: ["a": .nan]), watch: &watch) { _ in [] })
    }
    func testWatchRoundTripKeepsWatermarkAndEvidenceIDs() throws {
        var watch = Watch(); let note = Note(text: "price", createdAt: 5)
        _ = try Find().run(note: note, meeting: [chunk("a", 0, 5, seq: 4)], closed: false,
                          decision: Head(scores: ["a": 1]), watch: &watch) { _ in [] }
        XCTAssertEqual(watch.identifier("a"), "E1")
        watch = try JSONDecoder().decode(Watch.self, from: JSONEncoder().encode(watch))
        let next = try Find().run(note: note, meeting: [chunk("a", 0, 5, seq: 4), chunk("b", 6, 7, seq: 9)], closed: false,
                                 decision: Head(scores: ["a": 1, "b": 1]), watch: &watch) { _ in [] }
        XCTAssertEqual(next.evidence.filter(\.fresh).map { $0.chunk.id }, ["b"])
        XCTAssertEqual(watch.identifier("a"), "E1"); XCTAssertEqual(watch.identifier("b"), "E2")
        XCTAssertEqual(watch.seenThrough, 9)
    }
    func testUntimedFloorIsIndependentOfTimedHead() throws {
        var watch = Watch()
        let result = try Find().run(note: Note(text: "term", createdAt: nil), meeting: [], closed: true,
                                   decision: Head(scores: ["a": 0.779, "b": 0.78]), watch: &watch) { rung in
            rung == .vault ? [self.chunk("a", 0, 0), self.chunk("b", 0, 0)] : []
        }
        XCTAssertEqual(result.rung, .vault); XCTAssertEqual(result.evidence.map { $0.chunk.id }, ["b"])
    }
    func testExpansionDoesNotReintroduceBelowFloorOrOtherSource() {
        let seed = chunk("a", 10, 11), neighbor = chunk("b", 12, 13), low = chunk("c", 13, 14)
        let evidence = [Evidence(chunk: seed, relevance: 0.9, rung: .moment, fresh: true), Evidence(chunk: neighbor, relevance: 0.2, rung: .moment, fresh: true)]
        let found = FindResult(rung: .moment, evidence: evidence, candidates: evidence, holding: false, answerable: true)
        let groups = EvidencePack.groups(found, note: Note(text: "why?", createdAt: 12), chunks: [seed, neighbor, low], constants: EngineConstants())
        XCTAssertEqual(groups.flatMap { $0.map { $0.chunk.id } }, ["a", "b"])
    }
    func testAnsweredQueryWatchesBeyondItsOriginalMoment() throws {
        var note = Note(text: "price", createdAt: 5); note.line.text = "Price is ten dollars."
        var watch = Watch(); watch.text = note.matchingText; watch.seenThrough = 1
        let result = try Find().run(note: note, meeting: [chunk("old", 0, 5), chunk("new", 600, 605, seq: 2)], closed: false,
                                   decision: Head(scores: ["old": 0.9, "new": 0.8]), watch: &watch) { _ in XCTFail(); return [] }
        XCTAssertEqual(result.rung, .moment)
        XCTAssertTrue(result.evidence.contains { $0.chunk.id == "new" && $0.fresh })
    }
    func testListeningQueryCarriesNewAnswersAfterItsMomentCloses() throws {
        let note = Note(text: "price?", createdAt: 5)
        var watch = Watch(); watch.text = note.matchingText; watch.seenThrough = 1
        let chunks = [chunk("old", 0, 5), chunk("answer", 50, 55, seq: 2)]
        let first = try Find().run(note: note, meeting: chunks, closed: false, decision: Head(scores: ["old": 0.9, "answer": 0.8]), watch: &watch) { _ in [] }
        XCTAssertTrue(first.evidence.contains { $0.chunk.id == "answer" && $0.fresh })
        let repeated = try Find().run(note: note, meeting: chunks, closed: false, decision: Head(scores: ["old": 0.9, "answer": 0.8]), watch: &watch) { _ in [] }
        XCTAssertTrue(repeated.evidence.contains { $0.chunk.id == "answer" && !$0.fresh })
    }
    func testBudgetDropsWholeGroupsAndClipsOversizedGroupAtSentenceEnd() throws {
        var batch = EnrichmentBatch()
        let a = PromptEvidence(id: "E1", chunk: chunk("a", 0, 1).transcript)
        var b = PromptEvidence(id: "E2", chunk: chunk("b", 2, 3).transcript)
        b.chunk.text = "Short fact. A longer second fact that exceeds the limit."
        batch.excerpts = [a, b]
        batch.targets = [LineRequest(note: Note(text: "why", createdAt: 1), refs: ["E2", "E1"], fresh: ["E2", "E1"], previous: nil, groups: [["E2"], ["E1"]])]
        try batch.limitPromptTokens(15) { _, evidence in evidence.reduce(0) { $0 + $1.chunk.text.count } }
        XCTAssertEqual(batch.targets[0].refs, ["E2"])
        XCTAssertEqual(batch.evidence(for: batch.targets[0]).map { $0.chunk.text }, ["Short fact."])
    }
    func testQueryEditKeepsEvidenceIdentitiesAndReconsidersOldChunks() throws {
        var watch = Watch(); watch.text = "old"; watch.seenThrough = 9
        XCTAssertEqual(watch.identifier("a"), "E1")
        let result = try Find().run(note: Note(text: "new", createdAt: 5), meeting: [chunk("a", 0, 5, seq: 4)], closed: false,
                                   decision: Head(scores: ["a": 0.9]), watch: &watch) { _ in [] }
        XCTAssertTrue(result.evidence[0].fresh)
        XCTAssertEqual(watch.identifier("a"), "E1")
    }
    func testKeepRemainsAvailableWhileWriteGateHolds() throws {
        var watch = Watch()
        let found = try Find().run(note: Note(text: "price?", createdAt: 5), meeting: [chunk("a", 0, 5)], closed: false,
                                   decision: Head(scores: ["a": 0.2]), watch: &watch) { _ in [] }
        XCTAssertFalse(found.answerable)
        XCTAssertEqual(found.retained.map { $0.chunk.id }, ["a"])
    }
    func testShorthandFeaturesComeFromHeardWords() {
        XCTAssertEqual(EmbeddingDecisionModel.coverage("lww", in: "last right wins"), 1)
        XCTAssertEqual(EmbeddingDecisionModel.coverage("RK", in: "root kit"), 1)
        XCTAssertEqual(EmbeddingDecisionModel.coverage("dims file", in: "dimensions file"), 1)
        XCTAssertEqual(EmbeddingDecisionModel.coverage("pricing", in: "the deadline is Friday"), 0)
    }
    func testAnswerTurnKeepsTheQuestionAfterTwelveSeconds() {
        let chunks = [
            TranscriptChunk(id: "q", segmentID: "q", speaker: "A", start: 0, end: 2, text: "Nadia, what is blocking you?"),
            TranscriptChunk(id: "a", segmentID: "a", speaker: "B", start: 3, end: 15, text: "The migration is merged."),
            TranscriptChunk(id: "b", segmentID: "b", speaker: "B", start: 16, end: 28, text: "The staging replica is down, so I am blocked on Dmitri.")]
        XCTAssertEqual(EmbeddingDecisionModel.context(for: chunks[2], in: chunks).map(\.id), ["q", "a", "b"])
        let f = EmbeddingDecisionModel.contextualFeatures(jot: Note(text: "Nadia blocked?", createdAt: 29), chunk: chunks[2], cosine: 0.7, speakerChanged: false, neighbors: chunks)
        XCTAssertEqual(f[6], 0.5); XCTAssertEqual(f[7], 1)
    }
    func testCachedContextMatchesExporterAcrossChunkBoundaries() throws {
        var chunks = [chunk("a", 0, 1), chunk("b", 1, 2), chunk("c", 2, 3)]
        for i in chunks.indices { chunks[i].text = ["last", "write", "wins"][i] }
        let plain = EmbeddingDecisionModel.Head(feature_kind: "cheap", mean: Array(repeating: 0, count: 6), scale: Array(repeating: 1, count: 6), weights: Array(repeating: 0, count: 6), bias: -5, temperature: 1)
        let answer = EmbeddingDecisionModel.Head(feature_kind: "cheap", mean: Array(repeating: 0, count: 7), scale: Array(repeating: 1, count: 7), weights: Array(repeating: 0, count: 7), bias: 2, temperature: 1)
        let context = EmbeddingDecisionModel.Head(feature_kind: "cheap", mean: Array(repeating: 0, count: 8), scale: Array(repeating: 1, count: 8), weights: [0, 0, 0, 0, 0, 0, 0, 1], bias: 2, temperature: 1)
        let artifact = EmbeddingDecisionModel.Artifact(version: 2, embeddingModel: "test", relevanceThreshold: 0, answerabilityThreshold: 0.5, contextThreshold: 0.9, heads: ["relevance": plain, "answerability": answer, "contextual": context])
        let vectors = IndexVectors(modelID: "test", queries: ["lww": [1, 0]], chunks: chunks)
        let model = try EmbeddingDecisionModel(artifact: artifact, cache: vectors, chunks: chunks.map(\.transcript))
        let note = Note(text: "lww", createdAt: 3)
        let features = EmbeddingDecisionModel.contextualFeatures(jot: note, chunk: chunks[2].transcript, cosine: 1, speakerChanged: false, neighbors: chunks.map(\.transcript))
        XCTAssertEqual(features[7], 1)
        XCTAssertEqual(try model.relevance(jot: note, candidates: [chunks[2].transcript])[0], try context.probability(features), accuracy: 1e-12)
        XCTAssertLessThan(try model.updateRelevance(jot: note, candidates: [chunks[2].transcript])[0], 0.5)
    }
    func testBundledIdentityMismatchFailsClosed() throws {
        let vectors = IndexVectors(modelID: "another-model", queries: [:], chunks: [])
        XCTAssertThrowsError(try EmbeddingDecisionModel.bundled(cache: vectors, chunks: []))
    }
}
