import XCTest
@testable import WorkScribeCore
@testable import WorkScribe

private struct ReplayFixtureModel: TextModel {
    var line = "* **Budget:** The team will send the budget report on Monday."
    let displayName = "fixture", backend = TextBackend.llama, isAvailable = true
    func generate(_ request: TextRequest) async throws -> TextGeneration {
        let text = request.instruction.hasPrefix(NotePrompt.topicsHead) ? ""
            : line
        return TextGeneration(text: text, stats: TextStats(promptTokens: 50, generatedTokens: 12, totalMs: 100))
    }
    func stream(_ request: TextRequest) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func prewarm(_ request: TextRequest?) async {}
    func release() async {}
}

final class ReplayTests: XCTestCase {
    private func sample() throws -> ReplayCase {
        try JSONDecoder().decode(ReplayCase.self, from: Data(#"{"id":"fixture","status":"reviewed","speech":[{"id":"s1","speaker":"A","start":0,"end":5,"text":"The team will send the budget report on Monday."},{"id":"s2","speaker":"A","start":25,"end":26,"text":"SECRET_FUTURE on Tuesday."}],"jots":[{"id":"n1","text":"budget report","at":8}],"stop_at":30,"gold":{"SECRET_GOLD":true}}"#.utf8))
    }
    func testFinalizedHorizonAndValidation() throws {
        var c = try sample(); XCTAssertEqual(c.speech[0].finalizedAt, 5.5)
        try c.validate(); c.speech[0].final_at = 2
        XCTAssertThrowsError(try c.validate())
    }
    func testMissingGenerationFailsClosed() async throws {
        let models = ReplayModels(cache: .init(model: "fixture", embedding: .init(modelID: "fixture", dimension: 2)), real: false)
        do { _ = try await models.generate(TextRequest("missing", maxTokens: 10)); XCTFail() } catch {}
        XCTAssertEqual(models.misses.count, 1)
        XCTAssertThrowsError(try models.check())
    }
    func testRealReceiptReplaysIdenticallyAndRejectsDifferentSamplingSettings() async throws {
        let real = ReplayModels(cache: .init(model: "fixture", embedding: .init(modelID: "fixture", dimension: 2)), real: true, generator: ReplayFixtureModel(), embedder: FixtureEmbedder())
        let request = TextRequest("exact prompt", maxTokens: 10)
        _ = try await real.generate(request)
        let cached = ReplayModels(cache: real.cache, real: false)
        let value = try await cached.generate(request)
        XCTAssertEqual(value.text, real.cache.generations.values.first?.first?.text)
        XCTAssertEqual(cached.seconds, real.seconds)
        do { _ = try await cached.generate(TextRequest("exact prompt", maxTokens: 11)); XCTFail() } catch {}
    }
    func testPromptLocalIDsRetainQueryOwnershipInCallReceipts() async throws {
        let models = ReplayModels(cache: .init(model: "fixture", embedding: .init(modelID: "fixture", dimension: 2)), real: true, generator: ReplayFixtureModel())
        var note = Note(text: "budget", createdAt: nil); note.id = "n1"
        let request = LineRequest(note: note, refs: ["n1:E1"], fresh: ["n1:E1"], previous: nil, backgroundOnly: true)
        let source = PromptEvidence(id: "n1:E1", chunk: TranscriptChunk(id: "c1", segmentID: "v1", speaker: "", start: 0, end: 0, text: "Budget Monday."))
        _ = try await models.generate(TextRequest(LinePrompt.build(request, excerpts: [source]), maxTokens: 96, noteID: note.id))
        XCTAssertEqual(models.calls.first?.evidence_ids, ["n1:E1"])
    }
    func testSilentReplayHasZeroModelCalls() async throws {
        var c = try sample(); c.speech = []; c.jots = []; c.stop_at = 600
        let models = ReplayModels(cache: .init(model: "fixture", embedding: .init(modelID: "fixture", dimension: 2)), real: false)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let result = try await Replay.run(c, models: models, config: EngineConstants(), root: root, decisionModel: FixtureDecision())
        XCTAssertTrue(result.passes.isEmpty); XCTAssertTrue(models.calls.isEmpty); XCTAssertEqual(models.embedCalls, 0)
    }
    func testCachedVectorsCanBeRegroupedWithoutInventingModelTime() async throws {
        var cache = ReplayModels.Cache(model: "fixture", embedding: .init(modelID: "fixture", dimension: 2))
        for text in ["first", "second"] {
            cache.embedding.vectors[RetrievalText(text, query: true).key(modelID: "fixture")] = [1, 0]
        }
        let models = ReplayModels(cache: cache, real: false)
        let vectors = try await models.vectors(["first", "second"], role: .query)
        XCTAssertEqual(vectors, [[1, 0], [1, 0]])
        XCTAssertEqual(models.seconds, 0)
        XCTAssertEqual(models.embedHits, 1)
        do { _ = try await models.vectors(["missing"], role: .query); XCTFail() } catch {}
        XCTAssertThrowsError(try models.check())
    }
    func testTwoCachedRunsAreByteIdenticalAndNeverSeeFutureAtFirstLine() async throws {
        let c = try sample()
        let real = ReplayModels(cache: .init(model: "fixture", embedding: .init(modelID: "fixture", dimension: 2)), real: true, generator: ReplayFixtureModel(), embedder: FixtureEmbedder())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let baseline = try await Replay.run(c, models: real, config: EngineConstants(), root: root, decisionModel: FixtureDecision())
        XCTAssertFalse(baseline.rows.isEmpty)
        let first = try XCTUnwrap(baseline.rows.first { !$0.text.isEmpty })
        XCTAssertEqual(first.available_segment_ids, ["s1"])
        var outputs: [Data] = []
        for _ in 0..<2 {
            let cached = ReplayModels(cache: real.cache, real: false)
            let result = try await Replay.run(c, models: cached, config: EngineConstants(), root: root, decisionModel: FixtureDecision())
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            outputs.append(try encoder.encode(result.rows))
        }
        XCTAssertEqual(outputs[0], outputs[1])
    }
    func testRejectedLineHasAReasonAndAfterStopDoesNotDelaySettlement() async throws {
        let c = try sample()
        let models = ReplayModels(cache: .init(model: "fixture", embedding: .init(modelID: "fixture", dimension: 2)), real: true,
                                  generator: ReplayFixtureModel(line: "* It was discussed."), embedder: FixtureEmbedder())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let result = try await Replay.run(c, models: models, config: EngineConstants(), root: root, decisionModel: FixtureDecision())
        let attempts = result.passes.flatMap(\.calls).filter { $0.job == "line" }
        XCTAssertFalse(attempts.isEmpty)
        XCTAssertTrue(attempts.allSatisfy { $0.rejection == .tooShort })
        let settle = try XCTUnwrap(result.rows.last { $0.state == "quiet" || $0.state == "settled" })
        let background = try XCTUnwrap(result.passes.first { $0.cause == "after-stop" })
        XCTAssertLessThanOrEqual(settle.at, background.at)
    }
    struct BudgetHead: DecisionModel {
        let relevanceThreshold = 0.0, answerabilityThreshold = 0.5
        func relevance(jot: Note, candidates: [TranscriptChunk]) throws -> [Double] { candidates.map { $0.text.contains("budget") ? 0.9 : 0 } }
        func answerability(jot: Note, evidence: [TranscriptChunk]) throws -> Double { 1 }
    }
    func testAFindPassWithoutGenerationDoesNotThrottleTheFirstAnswer() async throws {
        let data = Data(#"{"id":"waiting","status":"synthetic","speech":[{"id":"s0","speaker":"A","start":0,"end":1,"text":"Hello everyone."},{"id":"s1","speaker":"A","start":13,"end":14,"text":"The team will send the budget report on Monday."}],"jots":[{"id":"n1","text":"budget report","at":6}],"stop_at":30}"#.utf8)
        let c = try JSONDecoder().decode(ReplayCase.self, from: data)
        let models = ReplayModels(cache: .init(model: "fixture", embedding: .init(modelID: "fixture", dimension: 2)), real: true, generator: ReplayFixtureModel(), embedder: FixtureEmbedder())
        let result = try await Replay.run(c, models: models, config: EngineConstants(), root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), decisionModel: BudgetHead())
        let first = try XCTUnwrap(result.rows.first { !$0.text.isEmpty })
        XCTAssertLessThan(first.at, 20)
    }
    func testVaultFixtureUsesTheCurrentIndexAndReportsItsActualSource() async throws {
        let note = ReplayCase.Vault(id: "glossary", title: "Budget glossary", markdown: "Budget report means the planning report.")
        let texts = MarkdownSource.passages(note.markdown, title: note.title, source: SourceID(.vault, note.id)).flatMap(Chunker.chunks).map(\.embeddedText)
        var cache = ReplayModels.Cache(model: "fixture", embedding: .init(modelID: "fixture", dimension: 256))
        let inputs = texts.map { RetrievalText($0, query: false) } + [RetrievalText("budget report", query: true)]
        for input in inputs { cache.embedding.vectors[input.key(modelID: "fixture")] = Array(repeating: 1 / 16, count: 256) }
        for batch in [Array(inputs.dropLast()), [inputs.last!]] {
            cache.embeddingSeconds[replayHash(batch.map { $0.key(modelID: "fixture") }.joined(separator: "\n"))] = [0]
        }
        let models = ReplayModels(cache: cache, real: false)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vault = try ReplayVault([note], root: root, models: models)
        try await vault.prepare()
        XCTAssertEqual(try vault.index.candidates(QueryVector(text: "budget report", vector: Array(repeating: 1 / 16, count: 256), model: "fixture"), scope: .vault(excluding: []), limit: 72).map { $0.source.ref }, ["glossary"])
        XCTAssertEqual(models.embedCalls, 0)
        XCTAssertEqual(models.embedHits, 1)
    }
    func testPairFeaturesUseTranscriptSpeakersAndTheBudgetedPack() throws {
        let chunks = [
            TranscriptChunk(id: "a", segmentID: "a", speaker: "A", start: 0, end: 1, text: "budget Monday"),
            TranscriptChunk(id: "b", segmentID: "b", speaker: "B", start: 1, end: 2, text: "other topic"),
            TranscriptChunk(id: "c", segmentID: "c", speaker: "A", start: 2, end: 3, text: "budget Tuesday")]
        var note = Note(text: "budget", createdAt: 3); note.id = "n"
        var plan = EnrichmentBatch()
        plan.targets = [.init(note: note, refs: ["E1", "E3"], fresh: [], previous: nil)]
        plan.excerpts = [.init(id: "E1", chunk: chunks[0]), .init(id: "E3", chunk: chunks[2])]
        var bounded = plan; bounded.targets[0].refs = ["E3"]
        var cache = ReplayModels.Cache(model: "fixture", embedding: .init(modelID: "fixture", dimension: 2))
        for input in [RetrievalText("budget", query: true)] + chunks.map({ RetrievalText($0.text, query: false) }) {
            cache.embedding.vectors[input.key(modelID: "fixture")] = [1, 0]
        }
        let observer = ReplayPlans()
        observer.record("candidates", plan, seconds: 0); observer.record("budgeted", bounded, seconds: 0)
        let pairs = try observer.pairs(caseID: "case", models: ReplayModels(cache: cache, real: false), chunks: chunks)
        XCTAssertEqual(pairs.first { $0.segment_id == "c" }?.cheap[2], 1)
        let answer = try XCTUnwrap(pairs.first { $0.task == "answerability" })
        XCTAssertEqual(answer.segment_ids, ["c"])
        XCTAssertEqual(answer.cheap[6], log(2), accuracy: 1e-10)
        cache.embedding.vectors.removeValue(forKey: RetrievalText(chunks[2].text, query: false).key(modelID: "fixture"))
        XCTAssertThrowsError(try observer.pairs(caseID: "case", models: ReplayModels(cache: cache, real: false), chunks: chunks))
    }
    func testSharedApplyDoesNotOverwriteAnEditedJotOrOwnedLine() throws {
        var c = try sample().meeting()
        c.segments = [Segment(source: "test", speaker: "A", start: 0, end: 5, text: "The team will send the budget report on Monday.")]
        var n = Note(text: "budget report", createdAt: 8); n.id = "n1"; c.notes = [n]
        let plan = try SelectionFixture.plan(c, matcher: LexicalMatcher(), incremental: true)
        let draft = Enrichment.fixture(plan: plan, output: "* **Budget:** The team will send the budget report on Monday.")
        c.notes![0].editText("completely different question")
        CurrentNoteEngine.apply(draft, to: &c, final: false)
        XCTAssertNil(c.notes![0].line.text)
        c.notes![0] = n; c.notes![0].editEnhancement(.init(topic: "Mine", text: "User words"))
        CurrentNoteEngine.apply(draft, to: &c, final: false)
        XCTAssertEqual(c.notes![0].line.text, "**Mine** User words")
    }
}
