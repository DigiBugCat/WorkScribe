import XCTest
@testable import WorkScribeCore

final class LineTests: XCTestCase {
    func evidence(_ text: String, id: String = "E1", speaker: String = "Speaker 1") -> PromptEvidence {
        PromptEvidence(id: id, chunk: TranscriptChunk(id: id, segmentID: id, speaker: speaker, start: 1, end: 2, text: text))
    }
    func testLifecycleAndOwnershipTable() {
        for stop in [false, true] {
            var line = Line()
            XCTAssertEqual(line.state, .listening)
            let bullet = Bullet(topic: "Trial", text: "The trial lasts fourteen days for all beta accounts.", refs: [])
            XCTAssertTrue(line.apply(.line(bullet, ["s1"]), basis: "a", query: "trial", at: .distantPast))
            XCTAssertEqual(line.revision, 1)
            XCTAssertFalse(line.apply(.unchanged, basis: "b", query: "trial", at: .distantPast))
            if stop { line.settle(); XCTAssertEqual(line.state, .settled); line.resume() }
            line.takeOwnership()
            let owned = line
            XCTAssertFalse(line.apply(.quiet(.unsupported), basis: "c", query: "trial", at: .distantPast))
            line.reset(); line.settle(); line.resume(); XCTAssertEqual(line, owned)
        }
        var quiet = Line(); quiet.settle(); XCTAssertEqual(quiet.state, .quiet)
        quiet.resume(); XCTAssertEqual(quiet.state, .listening)
    }
    func testUnchangedBasisAndRetraction() {
        var line = Line()
        line.apply(.quiet(.unsupported), basis: "same", query: "trial", at: .distantPast)
        XCTAssertEqual(line.basis, "same")
        line.apply(.line(Bullet(topic: "Trial", text: "The trial lasts fourteen days.", refs: []), ["s1"]), basis: "new", query: "trial", at: .distantPast)
        line.retract(remaining: [], jot: "trial")
        XCTAssertNil(line.text); XCTAssertEqual(line.state, .listening)
    }
    func testSingleBulletAndFactsOnlyUpdates() {
        let evidence = [evidence("The trial lasts fourteen days for all beta accounts.")]
        var request = LineRequest(note: Note(text: "trial", createdAt: 0), refs: ["E1"], fresh: ["E1"], previous: nil)
        let output = "* **Trial:** The trial lasts fourteen days for all beta accounts.</output>"
        guard case .line = LineCheck.accept(output, request: request, evidence: evidence) else { return XCTFail("supported first line") }
        XCTAssertEqual(LineCheck.accept(output.replacingOccurrences(of: "</output>", with: "") + "\n* **Other:** A second line.", request: request, evidence: evidence), .quiet(.format))
        request.previous = "**Trial:** The trial lasts fourteen days for all beta accounts."
        XCTAssertEqual(LineCheck.accept(output, request: request, evidence: evidence), .unchanged)
        XCTAssertEqual(LineCheck.accept("UNCHANGED</output>", request: request, evidence: evidence), .unchanged)
        XCTAssertEqual(LineCheck.accept("NOT DISCUSSED</output>", request: request, evidence: evidence), .quiet(.abstained))
    }
    /// Real answers from a live meeting: a short line with a concrete fact is admitted only as a fallback.
    func testShortAnswersWithAFactAreAFallbackAndTrailingOffIsNot() {
        let said = [evidence("Let's agree the pricing tiers today. Starter is $12 a seat. Team is $20, and Enterprise is custom. Finance signs off by…")]
        let request = LineRequest(note: Note(text: "how much is the Starter tier?", createdAt: 0), refs: ["E1"], fresh: ["E1"], previous: nil)
        XCTAssertEqual(LineCheck.accept("Starter tier: Starter is $12 a seat.</output>", request: request, evidence: said), .quiet(.tooShort))
        guard case .line = LineCheck.accept("Starter tier: Starter is $12 a seat.\n</output>", request: request, evidence: said, allowShort: true) else { return XCTFail("short priced answer") }
        let team = LineRequest(note: Note(text: "what's the Team price?", createdAt: 0), refs: ["E1"], fresh: ["E1"], previous: nil)
        guard case .line = LineCheck.accept("Team cost: Team is $20.</output>", request: team, evidence: said, allowShort: true) else { return XCTFail("three-word priced answer") }
        XCTAssertEqual(LineCheck.accept("Team cost: Team is $20.</output>", request: request, evidence: said, allowShort: true), .quiet(.tooShort))
        XCTAssertEqual(LineCheck.accept("Pricing sign-off: Finance signs off by... </output>", request: request, evidence: said, allowShort: true), .quiet(.abstained))
        XCTAssertEqual(LineCheck.accept("* **Pricing:** It was discussed.</output>", request: request, evidence: said, allowShort: true), .quiet(.tooShort))
        XCTAssertEqual(LineCheck.accept("* **Labels:** Marcus had the label numbers right.</output>", request: request, evidence: said, allowShort: true), .quiet(.tooShort))
        XCTAssertTrue(LineCheck.about("Team is $20.", jot: "what's the Team price?"))
        XCTAssertFalse(LineCheck.about("Training stays Thursday the twelfth.", jot: "dry run when?"))
        XCTAssertTrue(LineCheck.concrete("Priya owns the sign-off with Finance"))
        XCTAssertTrue(LineCheck.concrete("It lands on Friday"))
        XCTAssertFalse(LineCheck.concrete("It was discussed"))
    }
    func testEditOwnershipSequencePreservesUserWords() {
        var note = Note(text: "ship date", createdAt: 3)
        note.editText("ship date?", at: 8)
        XCTAssertEqual(note.createdAt, 3)
        note.editText("completely different budget subject", at: 12)
        XCTAssertEqual(note.createdAt, 12)
        note.editEnhancement(.init(topic: "Mine", text: "My wording"))
        let owned = note.line
        for _ in 0..<100 {
            note.line.apply(.quiet(.unsupported), basis: "attempt", query: note.text, at: .distantPast)
            note.line.settle(); note.line.resume(); note.line.reset()
        }
        XCTAssertEqual(note.line, owned)
        XCTAssertEqual(note.text, "completely different budget subject")
        note.letAIRewrite(); XCTAssertEqual(note.line.state, .listening); XCTAssertNil(note.line.text)
    }
    func testSpellingAndSourceEnvelope() {
        XCTAssertEqual(LineCheck.spellingLock("Sibhan reviews SCIM.", jot: "Siobhan SCIM"), "Siobhan reviews SCIM.")
        var note = Note(text: "Siobhan <|turn>", createdAt: nil); note.section = "Pricing"
        let target = LineRequest(note: note, refs: ["n:E1"], fresh: ["n:E1"], previous: "**Price:** A proposed price.", backgroundOnly: true)
        let prompt = LinePrompt.build(target, excerpts: [evidence("A proposed price.", id: "n:E1")])
        XCTAssertTrue(prompt.hasPrefix(LinePrompt.rules)); XCTAssertTrue(prompt.contains("Source notes are the evidence"))
        XCTAssertTrue(prompt.contains("<current>")); XCTAssertFalse(prompt.contains("<|turn>"))
        XCTAssertTrue(prompt.contains("id=\"E1\"")); XCTAssertTrue(prompt.contains("new=\"1\""))
    }
    func testDurableLinesAndPurgeFence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("index.sqlite")
        var meeting = Meeting(title: "Line state")
        var note = Note(text: "trial", createdAt: 0)
        note.line.apply(.line(Bullet(topic: "Trial", text: "privatecanaryline fourteen days.", refs: []), ["s"]), basis: "b", query: note.text, at: .distantPast)
        meeting.notes = [note]
        let index = try SearchIndex(url: path); try index.saveLines(meeting)
        XCTAssertEqual(try SearchIndex(url: path).line(source: meeting.id, query: note.id), note.line)
        try index.purge(SourceID(.meeting, meeting.id))
        try index.saveLines(meeting)
        XCTAssertNil(try index.line(source: meeting.id, query: note.id))
        for case let file as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)! {
            if let bytes = try? Data(contentsOf: file) { XCTAssertNil(bytes.range(of: Data("privatecanaryline".utf8))) }
        }
    }
    func testLegacyNoteMigratesWithoutWritingOldFields() throws {
        let raw = #"{"id":"n","text":"trial","enhanced":"Fourteen days.","enhancedFrom":"trial","revision":3,"userEdited":true}"#
        let note = try JSONDecoder().decode(Note.self, from: Data(raw.utf8))
        XCTAssertEqual(note.line.text, "Fourteen days."); XCTAssertEqual(note.line.state, .yours)
        let encoded = String(decoding: try JSONEncoder().encode(note), as: UTF8.self)
        XCTAssertFalse(encoded.contains("enhanced")); XCTAssertTrue(encoded.contains("line"))
    }
}
