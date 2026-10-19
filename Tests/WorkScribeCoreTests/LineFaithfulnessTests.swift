import XCTest
@testable import WorkScribeCore

final class LineFaithfulnessTests: XCTestCase {
    private func evidence(_ texts: String...) -> [PromptEvidence] {
        texts.enumerated().map { i, text in
            PromptEvidence(id: "E\(i)", chunk: TranscriptChunk(id: "s\(i)", segmentID: "s\(i)", speaker: "Speaker 1", start: Double(i), end: Double(i + 1), text: text))
        }
    }
    func testParaphraseAndProvenanceAreNotInventedNumbers() {
        XCTAssertTrue(LineFaithfulness.grounded("Speaker 2 described the annual team cost as twelve dollars per seat.", evidence: ["The model assumes twelve dollars per seat per year."], jot: "price"))
        XCTAssertFalse(LineFaithfulness.grounded("The cost is sixteen dollars.", evidence: ["The cost is twelve dollars."], jot: "price"))
    }
    func testQuantityMustComeFromEvidenceNotJot() {
        XCTAssertFalse(LineFaithfulness.grounded("The pilot lasts ninety days.", evidence: ["The pilot lasts fourteen days."], jot: "ninety days?"))
        XCTAssertTrue(LineFaithfulness.grounded("The pilot lasts fourteen days.", evidence: ["The pilot lasts fourteen days."], jot: "trial"))
    }
    func testFirstLinePriorityDoesNotLoopForUnanswerableJot() {
        var queue = FirstLinePriority()
        var note = Note(text: "unanswered", createdAt: 0)
        XCTAssertTrue(queue.receive([note]))
        XCTAssertFalse(queue.receive([note]))
        note.editText("different subject entirely", at: 2)
        XCTAssertTrue(queue.receive([note]))
        XCTAssertFalse(queue.receive([note]))
        XCTAssertTrue(queue.receive([note, Note(text: "new question", createdAt: 4)]))
    }

    func testOneUnmarkedLabelIsNormalizedButMultipleLinesAreRejected() {
        let sources = evidence("The trial lasts fourteen days for all beta accounts.")
        let request = LineRequest(note: Note(text: "trial", createdAt: 0), refs: ["E0"], fresh: ["E0"], previous: nil)
        let body = "Trial: The trial lasts fourteen days for all beta accounts."
        guard case .line(let line, _) = LineCheck.accept(body, request: request, evidence: sources) else { return XCTFail("one labelled answer") }
        XCTAssertEqual(line.topic, "Trial")
        XCTAssertEqual(LineCheck.accept(body + "\nPrice: A second answer is not one line.", request: request, evidence: sources), .quiet(.format))
        XCTAssertEqual(LineCheck.accept("This is an unlabelled paragraph.", request: request, evidence: sources), .quiet(.format))
        XCTAssertEqual(LineCheck.accept("Trial: The trial lasts ninety days for all beta accounts.", request: request, evidence: sources), .quiet(.unsupported))
    }

}
