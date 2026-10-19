import XCTest
import WorkScribeCore
@testable import WorkScribe

@MainActor final class FinalNoteTests: XCTestCase {
    func testFinalTopicsRecoverOmittedCitationsButRejectInventedReferences() throws {
        var meeting = Meeting(title: "Challenge")
        meeting.segments = [Segment(source: "system", speaker: "system:speaker-1", start: 470, end: 500,
            text: "Complete the Japan food hunt after disembarking at any station without using your phone. One team member must consume six of eight items within one hour.")]
        let uncovered = UncoveredDiscussion.excerpts(meeting)
        let enhancer = MeetingSynthesis(model: TextModels.model(for: .brief))
        let result = enhancer.groundedTopics("* **Japan food hunt:** Consume six of eight items within one hour without using a phone.", excerpts: uncovered)
        XCTAssertEqual(result.count, 1); XCTAssertEqual(result.first?.refs, ["U1"])
        XCTAssertTrue(enhancer.groundedTopics("* **Japan food hunt:** Consume six items. (U999)", excerpts: uncovered).isEmpty)
    }

}
