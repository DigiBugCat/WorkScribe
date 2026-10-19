import XCTest
import WorkScribeCore
@testable import WorkScribe

private actor BackgroundModel: TextModel {
    nonisolated let displayName = "Fixture"
    nonisolated let backend = TextBackend.llama
    nonisolated let isAvailable = true
    var prompts: [String] = []
    let invent: Bool
    init(invent: Bool = false) { self.invent = invent }
    func generate(_ request: TextRequest) async throws -> TextGeneration {
        prompts.append(request.instruction)
        return TextGeneration(text: invent ? "* **Budget:** The team approved a budget of 79 dollars."
            : "* **Budget:** The team will send the budget report on Monday.", stats: TextStats())
    }
    nonisolated func stream(_ request: TextRequest) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func prewarm(_ request: TextRequest?) async {}
    func release() async {}
}
final class NoteBackgroundTests: XCTestCase {
    private func meeting() -> Meeting {
        var meeting = Meeting(title: "Budget")
        meeting.status = "recording"
        meeting.segments = [Segment(source: "test", speaker: "Riley", start: 0, end: 10,
                                    text: "The team will send the budget report on Monday.")]
        meeting.notes = [Note(text: "budget report", createdAt: 8)]
        return meeting
    }
    func testBackgroundNumberCannotPassTheMeetingGroundingGate() async throws {
        let model = BackgroundModel(invent: true)
        let enhancer = Enrich(textModel: model, decisionModel: FixtureDecision(), embeddingSource: { FixtureEmbedder() })
        let draft = try await enhancer.enhance(meeting(), incremental: true)
        XCTAssertEqual(draft?.outcomes.values.first, .quiet(.unsupported))
    }
}
