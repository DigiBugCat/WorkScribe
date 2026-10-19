import XCTest
@testable import WorkScribeCore

final class CommitmentRecoveryTests: XCTestCase {
    func testExplicitAddressNamesAcceptingVoiceWithoutInventingOtherOwners() {
        let chunks = [
            TranscriptChunk(id: "a", segmentID: "a", speaker: "Speaker 1", start: 0, end: 4, text: "Marcus, what's the problem with the checklist?"),
            TranscriptChunk(id: "b", segmentID: "b", speaker: "Speaker 2", start: 5, end: 7, text: "It loses edits."),
            TranscriptChunk(id: "c", segmentID: "c", speaker: "Speaker 1", start: 8, end: 10, text: "Can you prototype the merge by Monday?"),
            TranscriptChunk(id: "d", segmentID: "d", speaker: "Speaker 2", start: 11, end: 12, text: "Yes, give me until Monday."),
            TranscriptChunk(id: "e", segmentID: "e", speaker: "Speaker 1", start: 13, end: 15, text: "I'll tell Halvorsen on Friday.")]
        let actions = Commitments.find(chunks)
        XCTAssertEqual(actions.first?.owner, "Marcus")
        XCTAssertNil(actions.last?.owner)
        var ambiguous = chunks
        ambiguous += [TranscriptChunk(id: "f", segmentID: "f", speaker: "Speaker 1", start: 16, end: 18, text: "Priya, can you check the report?"),
                      TranscriptChunk(id: "g", segmentID: "g", speaker: "Speaker 2", start: 19, end: 20, text: "Yes, I can.")]
        XCTAssertNil(Commitments.find(ambiguous).first?.owner)
    }
    func testNameSharedByTwoAnonymousVoicesDoesNotEstablishAnOwner() {
        let chunks = [
            TranscriptChunk(id: "a", segmentID: "a", speaker: "Speaker 1", start: 0, end: 4, text: "Marcus, can you check the report?"),
            TranscriptChunk(id: "b", segmentID: "b", speaker: "Speaker 2", start: 5, end: 7, text: "Yes, I will."),
            TranscriptChunk(id: "c", segmentID: "c", speaker: "Speaker 1", start: 8, end: 10, text: "Marcus, can you send the agenda?"),
            TranscriptChunk(id: "d", segmentID: "d", speaker: "Speaker 3", start: 11, end: 12, text: "Yes, I will.")]
        let actions = Commitments.find(chunks)
        XCTAssertEqual(actions.count, 2)
        XCTAssertTrue(actions.allSatisfy { $0.owner == nil })
    }
    func testUnknownVoiceRemainsAnonymousAndAssignedNameWins() {
        let question = TranscriptChunk(id: "a", segmentID: "a", speaker: "Speaker 1", start: 0, end: 4, text: "Marcus, can you check the report?")
        var answer = TranscriptChunk(id: "b", segmentID: "b", speaker: "Unidentified speaker", start: 5, end: 7, text: "Yes, I will.")
        XCTAssertNil(Commitments.find([question, answer]).first?.owner)
        answer.speaker = "Priya"
        XCTAssertEqual(Commitments.find([question, answer]).first?.owner, "Priya")
    }
}
