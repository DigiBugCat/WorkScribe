import XCTest
import WorkScribeCore
@testable import WorkScribe

private actor RetryModel: TextModel {
    nonisolated var displayName: String { "Retry fixture" }
    nonisolated var backend: TextBackend { .llama }
    nonisolated var isAvailable: Bool { true }
    var count = 0
    func generate(_ request: TextRequest) async throws -> TextGeneration {
        count += 1
        return TextGeneration(text: count == 1 ? "not discussed" : "* **Budget:** The budget report will be sent on Monday.", stats: TextStats())
    }
    nonisolated func stream(_ request: TextRequest) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func prewarm(_ request: TextRequest?) async {}
    func release() async {}
}

final class NoteRetryTests: XCTestCase {
    func testChangingHypothesisRetriesDespiteStableExcerptID() async throws {
        var meeting = Meeting(title: "Budget")
        meeting.notes = [Note(text: "budget", createdAt: 4)]
        var segment = Segment(source: "system", speaker: "system:speaker-1", start: 0, end: 5, text: "The budget report…")
        segment.id = "stable"
        meeting.segments = [segment]
        let model = RetryModel()
        // Keep a single enhancer, exactly as the live scheduler does.
        let live = Enrich(textModel: model, decisionModel: FixtureDecision(), embeddingSource: { FixtureEmbedder() })
        if let draft = try await live.enhance(meeting, incremental: true) { CurrentNoteEngine.apply(draft, to: &meeting, final: false, at: .distantPast) }
        if let draft = try await live.enhance(meeting, incremental: true) { CurrentNoteEngine.apply(draft, to: &meeting, final: false, at: .distantPast) }
        var count = await model.count; XCTAssertEqual(count, 1)
        meeting.segments[0].text = "The budget report will be sent on Monday."
        let draft = try await live.enhance(meeting, incremental: true)
        count = await model.count; XCTAssertEqual(count, 2)
        XCTAssertNotNil(draft?.outcomes[meeting.notes![0].id])
    }
}
