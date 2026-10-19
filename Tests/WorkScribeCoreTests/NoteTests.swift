import XCTest
@testable import WorkScribeCore

final class NoteTests: XCTestCase {
    func fixture() -> Meeting {
        var meeting = Meeting(title: "Planning")
        func segment(_ speaker: Int, _ start: Double, _ text: String) -> Segment {
            Segment(source: "system", speaker: "system:speaker-\(speaker)", start: start, end: start + 20, text: text)
        }
        meeting.segments = [
            segment(1, 0, "Let's start with the budget. Finance wants the Q3 marketing budget cut by ten percent before the board review."),
            segment(2, 20, "The vendor contract with Acme renews in November and legal still has not reviewed the indemnity clause."),
            segment(1, 300, "Unrelated, the office move is scheduled for the second week of January so everyone needs to pack their desks."),
            segment(2, 600, "On hiring we will open two backend roles and Priya will own the interview loop.")]
        meeting.speakerAssignments = ["system:speaker-1": SpeakerAssignment(name: "Maya")]
        return meeting
    }
    func refs(_ plan: EnrichmentBatch, _ note: Note, _ meeting: Meeting) -> [String] {
        let chunks = Dictionary(uniqueKeysWithValues: Chunker.transcript(meeting).map { ($0.id, $0.text) })
        return (plan.chunkRefs[note.id] ?? []).compactMap { chunks[$0] }
    }

    func testHandbackClearsOwnedQuoteAndRestartsListening() {
        var note=Note(text:"Plan",createdAt:0)
        var trace=AITrace();trace.revisions=[TraceRevision(version:1,text:"Original pencil.",reason:"Evidence",at:Date())];note.trace=trace
        note.editEnhancement(.init(topic:"",text:"My edit."));note.letAIRewrite()
        XCTAssertNil(note.line.text);XCTAssertEqual(note.line.owned,false)
    }
    func testLegacyTranscriptDecodesAndNotesRoundTrip() throws {
        let legacy = #"{"id":"7C0F5F2E-3B7A-4D47-9C55-6A1F0F7E0A11","title":"Old","startedAt":"2026-09-01T10:00:00Z","status":"complete","segments":[],"partials":{}}"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let meeting = try decoder.decode(Meeting.self, from: Data(legacy.utf8))
        XCTAssertNil(meeting.notes); XCTAssertNil(meeting.missedTopics)
        let note = try decoder.decode(Note.self, from: Data(#"{"id":"n","text":"ship fri"}"#.utf8))
        XCTAssertNil(note.createdAt); XCTAssertTrue(note.lineNeedsEvidence)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        var updated = meeting
        var typed = Note(text: "ship fri", createdAt: 12.5); typed.line.text = "**Release:** Ship Friday."; typed.line.revision = 2
        updated.notes = [typed]; updated.missedTopics = [MissedTopic(topic: "Office", text: "Move in January.", excerptRefs: ["a#0"])]
        try store.save(updated)
        XCTAssertEqual(try store.load(meeting.id).notes, [typed])
        XCTAssertEqual(try store.load(meeting.id).missedTopics?.first?.excerptRefs, ["a#0"])
    }

    func testChunksSplitLongSegmentsAtSentencesWithStableIDs() {
        var meeting = Meeting(title: "Long")
        let text = (1...12).map { "Sentence number \($0) has exactly seven words." }.joined(separator: " ")
        meeting.segments = [Segment(source: "system", speaker: "system:speaker-1", start: 0, end: 84, text: text)]
        let chunks = Chunker.transcript(meeting)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.text.hasSuffix(".") && $0.words <= 60 })
        XCTAssertEqual(chunks.map(\.id), Chunker.transcript(meeting).map(\.id))
        XCTAssertEqual(chunks.first?.start, 0); XCTAssertEqual(chunks.last?.end ?? 0, 84, accuracy: 0.001)
        XCTAssertEqual(chunks.map(\.words).reduce(0, +), 84)
    }

    func testLexicalMatcherHandlesShorthandPrefixes() throws {
        let scores = try LexicalMatcher().similarities(notes: ["Q3 mktg budg", "nothing related"],
                                                        chunks: ["The Q3 marketing budget is cut.", "Acme contract renewal."])
        XCTAssertGreaterThan(scores[0][0], 0.3)
        XCTAssertEqual(scores[0][1], 0)
        XCTAssertEqual(scores[1], [0, 0])
    }











    func testParserToleratesSloppyOutput() {
        let output = """
        Here are your enhanced notes:

        1. **Budget**: Finance wants the Q3 marketing budget cut by
        ten percent before the board review [E1].
        - [N2] **Acme:** Legal has not reviewed the indemnity clause (E2, E3).
        *   **Hiring:** Two backend roles open; Priya owns the loop.

        ## Additional discussion
        * **Office move:** The move is planned for January (U1, U3).
        Let me know if you need anything else.
        """
        let parsed = NoteOutput.parse(output)
        XCTAssertEqual(parsed.notes.map(\.topic), ["Budget", "Acme", "Hiring"])
        XCTAssertEqual(parsed.notes[0].text, "Finance wants the Q3 marketing budget cut by ten percent before the board review.")
        XCTAssertEqual(parsed.notes[0].refs, ["E1"]); XCTAssertEqual(parsed.notes[1].refs, ["E2", "E3"])
        XCTAssertEqual(parsed.missed.count, 1); XCTAssertEqual(parsed.missed[0].refs, ["U1", "U3"])
        XCTAssertEqual(parsed.missed[0].markdown, "**Office move:** The move is planned for January.")
        XCTAssertEqual(NoteOutput.parse("* **A:** one\n</output>\n* **B:** leaked").notes.count, 1)
        XCTAssertEqual(NoteOutput.parse("* **A:** one ‹fast-path›").notes[0].text, "one <fast-path>")
        XCTAssertEqual(NoteOutput.parse("* N95 masks: order more").notes[0].topic, "N95 masks")
        XCTAssertTrue(NoteOutput.parse("").notes.isEmpty)
    }




}
