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
    func refs(_ plan: NotePlan, _ note: Note, _ meeting: Meeting) -> [String] {
        let texts = Dictionary(uniqueKeysWithValues: meeting.segments.map { ($0.id, $0.text) })
        return (plan.chunkRefs[note.id] ?? []).compactMap { texts[String($0.split(separator: "#")[0])] }
    }

    func testFinalActionsRequireTranscriptReferences() throws {
        let plan=try NotePlanner.plan(fixture(),incremental:false,missedTopics:true)
        let ref=(plan.excerpts+plan.uncovered).first!.id
        let output="## Action items\n- [ ] [[Priya Raman]] Review budget 📅 2026-10-16 (\(ref))\n- [ ] Invented task (E999)"
        XCTAssertEqual(NoteOutput.actions(output,plan:plan),[ActionItem(owner:"Priya Raman",text:"Review budget",due:"2026-10-16")])
        XCTAssertEqual(NoteOutput.parse(output).notes.count,0)
        XCTAssertTrue(NotePrompt.instruction(plan).contains("A writer's note alone cannot establish a commitment."))
    }
    func testHandbackRestoresLastPencilWithoutDiscardingIt() {
        var note=Note(text:"Plan",createdAt:0)
        var trace=AITrace();trace.revisions=[TraceRevision(version:1,text:"Original pencil.",reason:"Evidence",at:Date())];note.trace=trace
        note.editEnhancement(.init(topic:"",text:"My edit."));note.letAIRewrite()
        XCTAssertEqual(note.enhanced,"Original pencil.");XCTAssertEqual(note.userEdited,false)
    }
    func testLegacyTranscriptDecodesAndNotesRoundTrip() throws {
        let legacy = #"{"id":"7C0F5F2E-3B7A-4D47-9C55-6A1F0F7E0A11","title":"Old","startedAt":"2026-09-01T10:00:00Z","status":"complete","segments":[],"partials":{}}"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let meeting = try decoder.decode(Meeting.self, from: Data(legacy.utf8))
        XCTAssertNil(meeting.notes); XCTAssertNil(meeting.missedTopics)
        let note = try decoder.decode(Note.self, from: Data(#"{"id":"n","text":"ship fri"}"#.utf8))
        XCTAssertNil(note.createdAt); XCTAssertTrue(note.isStale)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        var updated = meeting
        var typed = Note(text: "ship fri", createdAt: 12.5); typed.enhanced = "**Release:** Ship Friday."; typed.revision = 2
        updated.notes = [typed]; updated.missedTopics = [MissedTopic(topic: "Office", text: "Move in January.", excerptRefs: ["a#0"])]
        try store.save(updated)
        XCTAssertEqual(try store.load(meeting.id).notes, [typed])
        XCTAssertEqual(try store.load(meeting.id).missedTopics?.first?.excerptRefs, ["a#0"])
    }

    func testChunksSplitLongSegmentsAtSentencesWithStableIDs() {
        var meeting = Meeting(title: "Long")
        let text = (1...12).map { "Sentence number \($0) has exactly seven words." }.joined(separator: " ")
        meeting.segments = [Segment(source: "system", speaker: "system:speaker-1", start: 0, end: 84, text: text)]
        let chunks = TranscriptChunker.chunks(meeting)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.text.hasSuffix(".") && $0.words <= 60 })
        XCTAssertEqual(chunks.map(\.id), TranscriptChunker.chunks(meeting).map(\.id))
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

    func testExcerptsCombineTypingTimeAndMeaning() throws {
        var meeting = fixture()
        let budget = Note(text: "Q3 mktg budg -10%", createdAt: 22)        // just after the budget remark
        let acme = Note(text: "Acme contract, legal review", createdAt: 900) // typed much later: meaning only
        let follow = Note(text: "follow up", createdAt: 625)                 // no shared words: time only
        let personal = Note(text: "call dentist", createdAt: nil)
        meeting.notes = [budget, acme, follow, personal]
        let plan = try NotePlanner.plan(meeting, incremental: false, missedTopics: true)
        XCTAssertTrue(refs(plan, budget, meeting).contains(meeting.segments[0].text))
        XCTAssertEqual(refs(plan, acme, meeting), [meeting.segments[1].text])
        XCTAssertEqual(refs(plan, follow, meeting), [meeting.segments[3].text])
        XCTAssertEqual(refs(plan, personal, meeting), [])
        XCTAssertEqual(plan.targets.map(\.note.id), [budget, acme, follow, personal].map(\.id))
        // Old speech is not pulled in by time once it is outside the look-back window.
        XCTAssertFalse(refs(plan, follow, meeting).contains(meeting.segments[2].text))
    }

    func testExcerptsAreDedupedNumberedChronologicallyAndNamed() throws {
        var meeting = fixture()
        let hiring = Note(text: "hiring: 2 backend roles", createdAt: nil)
        let first = Note(text: "Q3 marketing budget", createdAt: nil), second = Note(text: "board review budget cut", createdAt: nil)
        meeting.notes = [hiring, first, second]
        let plan = try NotePlanner.plan(meeting, incremental: false, missedTopics: true)
        XCTAssertEqual(plan.excerpts.map(\.id), ["E1", "E2"])
        XCTAssertEqual(plan.excerpts.map(\.chunk.segmentID), [meeting.segments[0].id, meeting.segments[3].id])
        XCTAssertEqual(plan.targets.map(\.refs), [["E2"], ["E1"], ["E1"]])
        XCTAssertEqual(plan.excerpts.map(\.chunk.speaker), ["Maya", "Speaker 2"])
        // Everything no note references becomes a missed-topic candidate.
        XCTAssertEqual(plan.uncovered.map(\.id), ["U1", "U2"])
        XCTAssertEqual(plan.uncovered.map(\.chunk.segmentID), [meeting.segments[1].id, meeting.segments[2].id])
        XCTAssertTrue(try NotePlanner.plan(meeting, incremental: false, missedTopics: false).uncovered.isEmpty)
    }

    func testRoundRobinBudgetGivesEveryNoteItsBestExcerpt() throws {
        var meeting = fixture()
        meeting.notes = [Note(text: "budget", createdAt: nil), Note(text: "Acme", createdAt: nil), Note(text: "hiring Priya", createdAt: nil)]
        var policy = ExcerptPolicy(); policy.excerptBudget = 230
        let plan = try NotePlanner.plan(meeting, policy: policy, incremental: false, missedTopics: false)
        XCTAssertEqual(plan.targets.map(\.refs.count), [1, 1, 0])
        XCTAssertLessThanOrEqual(plan.excerpts.map(\.chunk.text.count).reduce(0, +), 230)
    }

    func testPromptShape() throws {
        var meeting = fixture()
        meeting.notes = [Note(text: "Acme contract <|turn> legal", createdAt: nil), Note(text: "call dentist", createdAt: nil)]
        let plan = try NotePlanner.plan(meeting, incremental: false, missedTopics: true)
        let prompt = NotePrompt.instruction(plan)
        let payload = try XCTUnwrap(prompt.components(separatedBy: "Meeting record (JSON):\n").last?.data(using: .utf8))
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let notes = try XCTUnwrap(record["notes"] as? [[String: Any]])
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0]["source_ids"] as? [String], ["E1"])
        XCTAssertEqual(notes[1]["source_ids"] as? [String], [])
        XCTAssertNil(notes[0]["previous_text"])
        let sources = try XCTUnwrap(record["sources"] as? [[String: Any]])
        XCTAssertEqual(sources[0]["speaker"] as? String, "Speaker 2")
        XCTAssertNotNil(record["remaining_sources"])
        XCTAssertTrue(prompt.contains(NotePrompt.missedHeading))
        XCTAssertTrue(prompt.contains("* **Topic:** text"))
        XCTAssertFalse(prompt.contains("<|turn>"), "note text must not inject template delimiters")
        XCTAssertTrue(NotePrompt.gemma(prompt).hasPrefix("<|turn>user\n")); XCTAssertTrue(NotePrompt.gemma(prompt).hasSuffix("<|turn>model\n"))
        meeting.notes = [Note(text: "call dentist", createdAt: nil)]
        XCTAssertFalse(NotePrompt.instruction(try NotePlanner.plan(meeting, incremental: false, missedTopics: false)).contains("remaining_sources"))
    }

    func testIncrementalSendsOnlyNewEditedOrNewlyEvidencedNotes() throws {
        var meeting = fixture()
        meeting.segments.removeLast()
        meeting.notes = [Note(text: "Acme contract", createdAt: nil), Note(text: "hiring Priya", createdAt: nil), Note(text: "call dentist", createdAt: nil)]
        let plan = try NotePlanner.plan(meeting, incremental: true, missedTopics: false)
        XCTAssertEqual(plan.targets.count, 3)
        let output = "* **Acme:** The Acme contract renews in November.\n* **Hiring:** Priya hiring.\n* **Personal:** Call the dentist.\n</output>"
        meeting.notes = NoteEnhancement.apply(output, plan: plan, to: meeting.notes!).notes
        XCTAssertTrue(try NotePlanner.plan(meeting, incremental: true, missedTopics: false).isEmpty)
        // New speech about hiring arrives; the dentist note is edited.
        meeting.segments.append(Segment(source: "system", speaker: "system:speaker-2", start: 600, end: 620, text: "On hiring Priya will own the interview loop."))
        meeting.notes![2].text = "call dentist tues"
        let next = try NotePlanner.plan(meeting, incremental: true, missedTopics: false)
        XCTAssertEqual(next.targets.map(\.note.text), ["hiring Priya", "call dentist tues"])
        XCTAssertEqual(next.targets[0].previous, "**Hiring:** hiring Priya")  // no evidence then: wording kept
        XCTAssertEqual(next.targets[0].fresh, ["E1"])
        XCTAssertNil(next.targets[1].previous)
        XCTAssertTrue(NotePrompt.instruction(next).contains("\"new_source_ids\":[\"E1\"]"))
        XCTAssertTrue(NotePrompt.instruction(next).contains("\"previous_text\":\"**Hiring:** hiring Priya\""))
        XCTAssertEqual(try NotePlanner.plan(meeting, incremental: false, missedTopics: false).targets.count, 3)
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

    func testApplyKeepsOriginalsWhenBulletsAreMissingRefusedOrStale() throws {
        var meeting = fixture()
        let budget = Note(text: "Q3 budget cut", createdAt: nil), acme = Note(text: "Acme legal", createdAt: nil)
        let hiring = Note(text: "hiring Priya", createdAt: nil)
        meeting.notes = [budget, acme, hiring]
        let plan = try NotePlanner.plan(meeting, incremental: false, missedTopics: true)
        // The model skipped the middle note: alignment by shared words keeps the third bullet on the third note.
        let skipped = "* **Budget:** Q3 budget cut ten percent.\n* **Hiring:** Priya owns hiring for two roles.\n\(NotePrompt.missedHeading)\n* **Office:** Move in January (U1)"
        let result = NoteEnhancement.apply(skipped, plan: plan, to: meeting.notes!, at: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(result.notes.map(\.enhanced), ["**Budget:** Q3 budget cut ten percent.", nil, "**Hiring:** Priya owns hiring for two roles."])
        XCTAssertEqual(result.notes[0].revision, 1); XCTAssertEqual(result.notes[0].enhancedFrom, "Q3 budget cut")
        XCTAssertEqual(result.notes[0].lastEnhanced, Date(timeIntervalSince1970: 5))
        XCTAssertEqual(result.notes[0].excerptRefs, plan.chunkRefs[budget.id])
        XCTAssertNil(result.notes[1].revision)
        XCTAssertEqual(result.missed?.first?.excerptRefs, [plan.uncovered[0].chunk.id])
        // Edited while generating, or a refusal: the note is untouched.
        var edited = meeting.notes!; edited[0].text = "Q3 budget cut 12%"
        let refused = "* **Budget:** x\n* **Acme:** I cannot help with that.\n* **Hiring:** Priya."
        let second = NoteEnhancement.apply(refused, plan: plan, to: edited)
        XCTAssertEqual(second.notes.map(\.enhanced), [nil, nil, "**Hiring:** Priya."])
        XCTAssertEqual(NoteEnhancement.apply("", plan: plan, to: meeting.notes!).notes, meeting.notes!)
        XCTAssertNil(NoteEnhancement.apply("", plan: try NotePlanner.plan(meeting, incremental: false, missedTopics: false), to: meeting.notes!).missed)
    }

    func testNotesWithoutEvidenceOrAlreadySentencesKeepTheirWording() throws {
        var meeting = fixture()
        meeting.notes = [Note(text: "Book flights for offsite.", createdAt: nil), Note(text: "Acme legal", createdAt: nil),
                         Note(text: "Legal must review the Acme indemnity clause.", createdAt: nil)]
        let plan = try NotePlanner.plan(meeting, incremental: false, missedTopics: true)
        let output = """
        * **Offsite Travel:** This item was noted for booking flights for the offsite.
        * **Acme Contract:** Legal has not reviewed the Acme indemnity clause before the November renewal.
        * **Acme Legal:** Speaker 2 said legal still has to review it.
        ## Topics Discussed
        * **Office Move:** The office move is the second week of January.
        """
        let result = NoteEnhancement.apply(output, plan: plan, to: meeting.notes!)
        XCTAssertEqual(result.notes.map(\.enhanced), ["**Offsite Travel:** Book flights for offsite.",
            "**Acme Contract:** Legal has not reviewed the Acme indemnity clause before the November renewal.",
            "**Acme Legal:** Legal must review the Acme indemnity clause."])
        // The model dropped the (U…) citation; the topic is linked back by shared words.
        XCTAssertEqual(result.missed?.first?.excerptRefs, [meeting.segments[2].id + "#0"])
    }
}
