import XCTest
import WorkScribeCore
@testable import WorkScribe

private actor SynthesisModel: TextModel {
    nonisolated let displayName = "Synthesis fixture"
    nonisolated let backend: TextBackend = .llama
    nonisolated let isAvailable = true
    var requests: [TextRequest] = []
    func generate(_ request: TextRequest) async throws -> TextGeneration {
        requests.append(request)
        return TextGeneration(text: "NOT DISCUSSED</output>", stats: TextStats())
    }
    nonisolated func stream(_ request: TextRequest) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func prewarm(_ request: TextRequest?) async {}
    func release() async {}
}

final class SynthesisBudgetTests: XCTestCase {
    func testLongUncoveredMeetingKeepsOptionalWorkInsideCallAndContextBudget() async throws {
        let model = SynthesisModel()
        var meeting = Meeting(title: "Long discussion")
        meeting.segments = (0..<200).map { i in
            Segment(source: "mic", speaker: "one", start: Double(i * 5), end: Double(i * 5 + 4), text: "The discussion covers the regional service catalogue and its existing distribution system item \(i).")
        }
        _ = try await MeetingSynthesis(model: model).afterStop(meeting)
        let requests = await model.requests
        XCTAssertFalse(requests.isEmpty)
        XCTAssertLessThanOrEqual(requests.count, EngineConstants.synthesisCalls)
        for request in requests { XCTAssertTrue(try EvidenceBudget.synthesisFits(request.instruction)) }
    }
}
