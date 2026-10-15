import XCTest
@testable import WorkScribeCore

final class NoteDocumentTests: XCTestCase {
    func testVerbatimUnicodeBlocksAndFinalize() throws {
        let source = "# My heading\n\n- [ ] café 👩🏽‍💻\n  - [[nested]]\n\nUser paragraph\n"
        let range = (source as NSString).range(of: "- [ ] café 👩🏽‍💻\n  - [[nested]]")
        let b = NoteDocument.Block(id: "one", from: range.location, to: range.location + range.length,
                                   text: (source as NSString).substring(with: range), at: 2)
        let doc = NoteDocument(path: "/tmp/test.md", source: source, blocks: [b])
        try doc.validate()
        var meeting = Meeting(title: "Meeting")
        var note = Note(text: b.text, createdAt: 2); note.id = "one"; note.enhanced = "**Plan:** Add offline support."
        meeting.notes = [note]; meeting.brief = "Offline support."
        let final = try doc.finalizedText(meeting: meeting)
        XCTAssertTrue(final.contains(b.text + "\n  *Add offline support.*"))
        XCTAssertTrue(final.contains("User paragraph\n"))
        XCTAssertFalse(final.contains("^e1")); XCTAssertFalse(final.contains("workscribe://"))
    }
    func testNewNoteHasOneTitleAndStartsAtBullet() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let vault=VaultStore(root:root.appendingPathComponent("Vault"),stateDirectory:root.appendingPathComponent("State"))
        let doc=try vault.openDocument(Meeting(title:"A meeting"))
        XCTAssertFalse(doc.source.contains("# A meeting"));XCTAssertTrue(doc.source.hasSuffix("\n\n- "))
        XCTAssertTrue(doc.source.contains("workscribe:"));XCTAssertTrue(doc.source.contains("tags:"))
    }
    func testBriefSpacingAndTranscriptTaskDeduplication() throws {
        var meeting=Meeting(title:"A meeting");meeting.brief="A short brief."
        meeting.actionItems=[ActionItem(owner:"Priya",text:"SEND   PRD"),ActionItem(owner:"Marcus Chen",text:"Review a_b",due:"2026-10-16")]
        meeting.missedTopics=[MissedTopic(topic:"Risk",text:"Check *scope*",excerptRefs:[])]
        let source="---\nworkscribe: m-1\n---\n\n- [ ] send PRD\n"
        let output=try NoteDocument(path:"/tmp/test",source:source).finalizedText(meeting:meeting)
        XCTAssertTrue(output.contains("---\n\n*A short brief.*\n\n- [ ] send PRD"))
        XCTAssertEqual(output.components(separatedBy:"send PRD").count,2)
        XCTAssertFalse(output.contains("SEND   PRD"))
        XCTAssertTrue(output.contains("- [ ] [[Marcus Chen]] Review a\\_b 📅 2026-10-16"))
        XCTAssertTrue(output.contains("- *Risk. Check \\*scope\\**"))
        XCTAssertLessThan(output.range(of:"Also discussed")!.lowerBound,output.range(of:"Action items")!.lowerBound)
    }
    func testFinalInsertionsPreserveUTF16SourceAndMetadataOrder() throws {
        var m=Meeting(title:"Test");m.endedAt=m.startedAt.addingTimeInterval(120);m.attendees=["Priya Raman"];m.brief="Short brief."
        let source="---\ndate: 2026-10-14 10:02\ntags:\n  - meeting\nworkscribe: m1\n---\n\n- café 👩🏽‍💻\n"
        let range=(source as NSString).range(of:"- café 👩🏽‍💻")
        let d=NoteDocument(path:"/test",source:source,blocks:[.init(id:"n",from:range.location,to:NSMaxRange(range),text:"- café 👩🏽‍💻")])
        var n=Note(text:"- café 👩🏽‍💻",createdAt:0);n.id="n";n.enhanced="**Detail:** Unicode stays.";m.notes=[n]
        let text=NSMutableString(string:source)
        for i in try d.finalizedInsertions(meeting:m).reversed(){text.insert(i.text,at:i.at)}
        let result=try d.finalizedText(meeting:m)
        XCTAssertEqual(text as String,result)
        XCTAssertTrue(result.contains("date: 2026-10-14 10:02\nduration: 2 min\nattendees:\n  - \"[[Priya Raman]]\"\ntags:"))
        XCTAssertTrue(result.contains("- café 👩🏽‍💻\n  *Unicode stays.*"))
    }
    func testBulkSyncDeletesReordersAndPreservesFirstTime() throws {
        var a = Note(text: "a", createdAt: 4); a.id = "a"
        var b = Note(text: "b", createdAt: 6); b.id = "b"
        let doc = NoteDocument(path: "/tmp/a", source: "b edited\n\nc", blocks: [
            .init(id:"b",from:0,to:8,text:"b edited",at:100), .init(id:"c",from:10,to:11,text:"c",at:7)])
        try doc.validate()
        let notes = doc.notes(previous: [a,b])
        XCTAssertEqual(notes.map(\.id), ["b","c"]); XCTAssertEqual(notes.map(\.createdAt), [6,7])
        XCTAssertEqual(notes[0].text,"b edited")
    }
    func testOwnedTextDoesNotDuplicateAtFinalization() throws {
        let source = "words\n\n> My edited line"
        let doc = NoteDocument(path:"/tmp/a",source:source,blocks:[.init(id:"a",from:0,to:5,text:"words",owned:.init(from:7,to:23,text:"> My edited line"))])
        try doc.validate()
        var meeting=Meeting(title:"Test"); meeting.notes=doc.notes(previous:[])
        XCTAssertEqual(meeting.notes?[0].userEdited,true)
        XCTAssertEqual(try doc.finalizedText(meeting:meeting).components(separatedBy:"> My edited line").count,2)
    }
    func testRejectsDuplicateInvalidAndOverlappingRanges() {
        let b=NoteDocument.Block(id:"a",from:0,to:3,text:"abc")
        XCTAssertThrowsError(try NoteDocument(path:"/tmp/a",source:"abc",blocks:[b,b]).validate())
        XCTAssertThrowsError(try NoteDocument(path:"/tmp/a",source:"abc",blocks:[.init(id:"a",from:0,to:30,text:"abc")]).validate())
    }
    func testSameFileRenameConflictAndIdempotentFinalization() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let vault=VaultStore(root:root.appendingPathComponent("Vault"),stateDirectory:root.appendingPathComponent("State"))
        var meeting=Meeting(title:"Original"); var d=try vault.openDocument(meeting)
        let original=URL(fileURLWithPath:d.path)
        let source=d.source+"untouchable\n"; try source.write(to:original,atomically:true,encoding:.utf8)
        d.source=source; d.blocks=[.init(id:"a",from:(source as NSString).range(of:"untouchable").location,to:(source as NSString).range(of:"untouchable").location+11,text:"untouchable")]
        meeting.document=d; meeting.notes=d.notes(previous:[]); meeting.notes?[0].enhanced="AI line"
        let moved=original.deletingLastPathComponent().appendingPathComponent("Renamed.md")
        try FileManager.default.moveItem(at:original,to:moved)
        XCTAssertEqual(try vault.finalizeDocument(meeting),moved.path)
        let final=try String(contentsOf:moved,encoding:.utf8)
        XCTAssertTrue(final.contains("untouchable\n*AI line*"))
        meeting.document?.finalized=true
        XCTAssertEqual(try vault.finalizeDocument(meeting),moved.path)
        XCTAssertEqual(try String(contentsOf:moved,encoding:.utf8),final)
        meeting.document?.finalized=false
        XCTAssertEqual(try vault.finalizeDocument(meeting),moved.path) // replay after rename-before-journal crash
        try (final + "external edit").write(to:moved,atomically:true,encoding:.utf8)
        let conflict = try vault.finalizeDocument(meeting)
        XCTAssertTrue(conflict.hasSuffix(" (WorkScribe).md"))
        XCTAssertTrue(try String(contentsOfFile:conflict,encoding:.utf8).contains("*AI line*"))
        XCTAssertEqual(try String(contentsOf:moved,encoding:.utf8),final + "external edit")
    }
}

extension NoteDocumentTests {
    func testDeadlineRebaseNeverGuessesEditedOrAmbiguousBlocks() throws {
        let source = "keep\n\nedit\n\nduplicate\n"
        let d = NoteDocument(path:"/tmp/a",source:source,blocks:[
            .init(id:"a",from:0,to:4,text:"keep"),.init(id:"b",from:6,to:10,text:"edit"),
            .init(id:"c",from:12,to:21,text:"duplicate")])
        let current="# New heading\n\nkeep\n\nmy rewritten text\n\nduplicate\n\nduplicate\n"
        let rebase=d.rebased(on:current)
        try rebase.validate()
        XCTAssertEqual(rebase.blocks.map(\.id),["a"])
        XCTAssertEqual(rebase.source,current)
        var m=Meeting(title:"Fixture"); var n=Note(text:"keep",createdAt:0);n.id="a";n.enhanced="AI detail";m.notes=[n]
        let final=try rebase.finalizedText(meeting:m)
        XCTAssertTrue(final.contains("my rewritten text"));XCTAssertTrue(final.contains("keep\n*AI detail*"))
        XCTAssertEqual(final.components(separatedBy:"duplicate").count,3)
    }
}
extension NoteDocumentTests {
    func testOpeningMigratesExistingJotsWithoutTheirTransientAI() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let vault=VaultStore(root:root.appendingPathComponent("Vault"),stateDirectory:root.appendingPathComponent("State"))
        var m=Meeting(title:"Early jots");var n=Note(text:"my original shorthand",createdAt:3);n.enhanced="Transient AI"
        m.notes=[n];let d=try vault.openDocument(m)
        try d.validate();XCTAssertTrue(d.source.contains(n.text));XCTAssertFalse(d.source.contains("Transient AI"))
        XCTAssertEqual(d.blocks.first?.id,n.id);XCTAssertEqual(d.blocks.first?.at,3)
    }
}

extension NoteDocumentTests {
    func testInkAndPencilMarkdownHasBriefAndEscapedContinuation() throws {
        let source="---\nworkscribe_id: test\n---\n# Notes\n\n- shorthand\n"
        let at=(source as NSString).range(of:"- shorthand").location
        let d=NoteDocument(path:"/test",source:source,blocks:[.init(id:"n",from:at,to:at+11,text:"- shorthand")])
        var m=Meeting(title:"Test");var n=Note(text:"- shorthand",createdAt:0);n.id="n";n.enhanced="**Topic.** a_b *literal*";m.notes=[n];m.brief="A brief.";m.missedTopics=[.init(topic:"Other",text:"Fact",excerptRefs:[])]
        let final=try d.finalizedText(meeting:m)
        XCTAssertTrue(final.hasPrefix("---\nworkscribe_id: test\n---\n\n*A brief.*"))
        XCTAssertTrue(final.contains("- shorthand\n  *a\\_b \\*literal\\**"))
        XCTAssertTrue(final.contains("## Also discussed"));XCTAssertFalse(final.contains("**Topic.**"))
    }
}
