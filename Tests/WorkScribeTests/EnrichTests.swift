import XCTest
import WorkScribeCore
@testable import WorkScribe

private actor LineModel: TextModel {
    nonisolated let displayName = "Line fixture"
    nonisolated let backend: TextBackend = .llama
    nonisolated let isAvailable = true
    var requests: [TextRequest] = []
    func generate(_ request: TextRequest) async throws -> TextGeneration {
        requests.append(request)
        return TextGeneration(text: "* **Trial:** The trial lasts fourteen days for all beta accounts.</output>", stats: TextStats())
    }
    nonisolated func stream(_ request: TextRequest) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func prewarm(_ request: TextRequest?) async {}
    func release() async {}
}
final class EnrichTests: XCTestCase {
    func testOnePromptBasisAndApplyGuards() async throws {
        let model = LineModel()
        let engine = Enrich(textModel: model, decisionModel: FixtureDecision(), embeddingSource: { FixtureEmbedder() })
        var meeting = Meeting(title: "Trial")
        meeting.notes = [Note(text: "trial", createdAt: 2)]
        meeting.segments = [Segment(source: "mic", speaker: "one", start: 0, end: 4, text: "The trial lasts fourteen days for all beta accounts.")]
        let pending = try await engine.enhance(meeting, incremental: true)
        let draft = try XCTUnwrap(pending)
        var edited = meeting; edited.notes![0].editText("other subject entirely")
        XCTAssertTrue(CurrentNoteEngine.apply(draft, to: &edited, final: false, at: .distantPast))
        XCTAssertNil(edited.notes![0].line.text)
        CurrentNoteEngine.apply(draft, to: &meeting, final: false, at: .distantPast)
        XCTAssertNotNil(meeting.notes![0].line.text)
        let repeatResult = try await engine.enhance(meeting, incremental: false)
        XCTAssertNil(repeatResult)
        let requests = await model.requests
        XCTAssertEqual(requests.count, 1); XCTAssertEqual(requests[0].maxTokens, 96)
        XCTAssertEqual(requests[0].cacheablePrefix, LinePrompt.rules)
        XCTAssertEqual(CurrentNoteEngine.due(now: 1, lastRun: 0, firstLine: true), 1)
    }
}

private actor CorrectingLineModel: TextModel {
    nonisolated let displayName = "Corrective line fixture"
    nonisolated let backend: TextBackend = .llama
    nonisolated let isAvailable = true
    let repairs: Bool
    var requests: [TextRequest] = []
    init(repairs: Bool) { self.repairs = repairs }
    func generate(_ request: TextRequest) async throws -> TextGeneration {
        requests.append(request)
        return TextGeneration(text: repairs && requests.count == 2
            ? "* **Trial:** The trial lasts fourteen days for all beta accounts.</output>"
            : "* **Trial:** The trial lasts ninety days for all beta accounts.</output>", stats: TextStats())
    }
    nonisolated func stream(_ request: TextRequest) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func prewarm(_ request: TextRequest?) async {}
    func release() async {}
}

extension EnrichTests {
    func testCorrectiveRetryIsBoundedAndCarriesReason() async throws {
        for repairs in [false, true] {
            let model = CorrectingLineModel(repairs: repairs)
            let engine = Enrich(textModel: model, decisionModel: FixtureDecision(), embeddingSource: { FixtureEmbedder() })
            var meeting = Meeting(title: "Trial")
            meeting.notes = [Note(text: "trial", createdAt: 2)]
            meeting.segments = [Segment(source: "mic", speaker: "one", start: 0, end: 4, text: "The trial lasts fourteen days for all beta accounts.")]
            let pending = try await engine.enhance(meeting, incremental: true)
            let draft = try XCTUnwrap(pending)
            CurrentNoteEngine.apply(draft, to: &meeting, final: false, at: .distantPast)
            let requests = await model.requests
            XCTAssertEqual(requests.count, 2)
            XCTAssertTrue(requests[1].instruction.contains("<correction>Omit unsupported numbers."))
            XCTAssertEqual(meeting.notes![0].line.text != nil, repairs)
            let repeatResult = try await engine.enhance(meeting, incremental: false)
            XCTAssertNil(repeatResult)
            let finalCount = await model.requests.count
            XCTAssertEqual(finalCount, 2)
        }
    }
}

extension EnrichTests {
    func testConsumedEvidenceDoesNotCallGeneratorAgain() async throws {
        let model = LineModel()
        let engine = Enrich(textModel: model, decisionModel: FixtureDecision(), embeddingSource: { FixtureEmbedder() })
        var meeting = Meeting(title: "Trial")
        meeting.notes = [Note(text: "trial", createdAt: 2)]
        meeting.segments = [Segment(source: "mic", speaker: "one", start: 0, end: 4, text: "The trial lasts fourteen days for all beta accounts.")]
        let initial = try await engine.enhance(meeting, incremental: true)
        CurrentNoteEngine.apply(try XCTUnwrap(initial), to: &meeting, final: false)
        XCTAssertNotNil(meeting.notes![0].line.attemptedEvidence)
        let repeated = try await engine.enhance(meeting, incremental: true)
        XCTAssertNil(repeated)
        let calls = await model.requests.count
        XCTAssertEqual(calls, 1)
    }
}

extension EnrichTests {
    func testIncrementalPassYieldsOneLineAndPrioritizesNewestUnansweredJot() async throws {
        let model = LineModel()
        let engine = Enrich(textModel: model, decisionModel: FixtureDecision(), embeddingSource: { FixtureEmbedder() })
        var meeting = Meeting(title: "Trial")
        meeting.notes = [Note(text: "trial", createdAt: 1), Note(text: "trial", createdAt: 2), Note(text: "trial", createdAt: 3)]
        meeting.segments = [Segment(source: "mic", speaker: "one", start: 0, end: 4, text: "The trial lasts fourteen days for all beta accounts.")]
        let expected = meeting.notes!.reversed().map(\.id)
        for id in expected {
            let draft = try await engine.enhance(meeting, incremental: true)
            let produced = try XCTUnwrap(draft)
            XCTAssertEqual(Set(produced.outcomes.keys), [id])
            CurrentNoteEngine.apply(produced, to: &meeting, final: false)
        }
        let repeated = try await engine.enhance(meeting, incremental: true)
        XCTAssertNil(repeated)
        let requests = await model.requests
        XCTAssertEqual(requests.compactMap(\.noteID), expected)
    }
}
