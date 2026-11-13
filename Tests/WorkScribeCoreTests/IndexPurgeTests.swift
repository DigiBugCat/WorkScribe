import XCTest
@testable import WorkScribeCore

/// Counterexamples from `formal/tla/IndexPurge.tla`, on the real index and real SQLite.
final class IndexPurgeTests: XCTestCase {
    private var root: URL!
    private let meeting = "6C1F4B0E-7D0B-4E0A-9C55-0B1E3A1D2F10"
    private var folder: String { root.appendingPathComponent("Meetings/" + meeting).path }
    private var meetingRoot: String { AttachmentOwner.meeting(meeting).indexRoot }

    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("index-purge-" + UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func makeIndex() throws -> SearchIndex { try SearchIndex(url: root.appendingPathComponent("index.sqlite")) }
    private func transcript(_ index: SearchIndex, of id: String? = nil, _ text: String = "the launch moves to the ninth") throws {
        try index.replace(kind: .meeting, ref: id ?? meeting, title: "Planning", fingerprint: UUID().uuidString, modelID: nil,
                          chunks: [Chunk(kind: .meetingSegment, modality: .text, start: 0, end: 5, text: text)])
    }
    /// An attachment as `AttachmentIndexer` indexes it: a file source under the owner's root.
    private func attach(_ name: String, _ text: String, to index: SearchIndex, under folder: String? = nil, root: String? = nil) throws {
        try index.replace(kind: .file, ref: (folder ?? self.folder) + "/attachments/" + name, root: root ?? meetingRoot, title: name,
                          fingerprint: UUID().uuidString, modelID: nil, chunks: [Chunk(kind: .document, modality: .text, text: text)])
    }
    private func hits(_ word: String, in index: SearchIndex) throws -> Int { try index.search(SearchRequest(word)).hits.count }

    /// `Gone`, the code as found. `IndexService.purgeMeeting` listed what to delete, then set the fences, then
    /// deleted what it had listed, each in its own statement. Indexing runs at the same time, off that actor.
    /// This is that order, with an attachment's words arriving between the listing and the fences: the purge
    /// completes and the attachment is still searchable. (The app no longer purges in this order; see the next test.)
    func testListingBeforeFencingLetsWordsAppliedInBetweenSurviveThePurge() throws {
        let index = try makeIndex()
        try transcript(index)
        var refs = [meeting]
        for kind in [SourceKind.meeting, .file] {
            for source in try index.sources(kind: kind) where source.ref.hasPrefix(folder + "/") || source.root == meetingRoot { refs.append(source.ref) }
        }
        try attach("late.md", "quokkaplan budget figures", to: index)        // the indexer's transaction lands here
        try index.setMeta("purged:" + meeting, "1")
        try index.setMeta("purged:" + meetingRoot, "1")
        try index.purge(refs: refs)
        XCTAssertEqual(try hits("launch", in: index), 0)
        XCTAssertEqual(try hits("quokkaplan", in: index), 1, "the defect: the meeting is purged and its attachment can still be found")
    }

    /// `Gone`, as fixed: fences, listing and deletion are one transaction, so words are either already there
    /// and deleted, or arrive afterwards and are refused.
    func testAPurgedMeetingLeavesNothingBehindAndTakesNothingBack() throws {
        let index = try makeIndex()
        let other = "A0A0A0A0-1111-4222-8333-444455556666"
        let conversation = AttachmentOwner.conversation("C1").indexRoot, unrelated = AttachmentOwner.conversation("C2").indexRoot
        try transcript(index)
        try transcript(index, of: other, "the offsite is in march")
        try attach("early.md", "wombatnotes on pricing", to: index)
        try attach("asked.md", "numbatquestion context", to: index, under: root.appendingPathComponent("Conversations/C1").path, root: conversation)
        try attach("kept.md", "bilbykeeps this", to: index, under: root.appendingPathComponent("Conversations/C2").path, root: unrelated)

        try index.purge(meeting: meeting, folder: folder, roots: [meetingRoot, conversation])

        XCTAssertEqual(try hits("launch", in: index), 0)
        XCTAssertEqual(try hits("wombatnotes", in: index), 0)
        XCTAssertEqual(try hits("numbatquestion", in: index), 0, "what was attached to a conversation deleted with the meeting")
        XCTAssertEqual(try hits("offsite", in: index), 1, "another meeting is untouched")
        XCTAssertEqual(try hits("bilbykeeps", in: index), 1, "and so is a conversation that is not about this meeting")

        // Words that were still being read when Done was pressed arrive now, and the meeting indexer comes round again.
        try attach("late.md", "quokkaplan budget figures", to: index)
        try attach("late-answer.md", "bandicoot follow-up", to: index, under: root.appendingPathComponent("Conversations/C1").path, root: conversation)
        try transcript(index)
        XCTAssertEqual(try hits("quokkaplan", in: index), 0)
        XCTAssertEqual(try hits("bandicoot", in: index), 0)
        XCTAssertEqual(try hits("launch", in: index), 0)
        XCTAssertTrue(try index.sources(kind: .file).allSatisfy { $0.root == unrelated }, "no source of the meeting or its conversation is left")
    }

    /// The same, with the indexer really running on another thread while meetings are purged.
    func testWordsAppliedAtAnyMomentOfAPurgeDoNotSurviveIt() throws {
        let index = try makeIndex()
        for round in 0..<25 {
            let id = UUID().uuidString, folder = root.appendingPathComponent("Meetings/" + id).path
            let owner = AttachmentOwner.meeting(id).indexRoot
            try transcript(index, of: id, "round \(round) transcript")
            let indexing = DispatchGroup()
            DispatchQueue.global().async(group: indexing) {
                for n in 0..<30 {
                    try? index.replace(kind: .file, ref: folder + "/attachments/\(n).md", root: owner, title: "\(n)", fingerprint: "\(n)", modelID: nil,
                                       chunks: [Chunk(kind: .document, modality: .text, text: "attachment \(n) of round \(round)")])
                }
            }
            usleep(UInt32.random(in: 0...1_500))
            try index.purge(meeting: id, folder: folder, roots: [owner])
            indexing.wait()
            XCTAssertNil(try index.source(ref: id))
            XCTAssertFalse(try index.sources(kind: .file).contains { $0.root == owner }, "round \(round): an attachment outlived its meeting")
        }
    }

    private func onDisk(_ token: String) -> Bool {
        ["", "-wal"].contains { suffix in
            (try? Data(contentsOf: URL(fileURLWithPath: root.appendingPathComponent("index.sqlite").path + suffix)))?.range(of: Data(token.utf8)) != nil
        }
    }

    /// `NothingLeftOnDisk`. Another connection (the MCP server reads this index from its own process) is in
    /// the middle of a read. SQLite then answers the purge's checkpoint with "busy", not with an error; the
    /// purge took that for success and reported the meeting purged with its text still in the files.
    func testAPurgeThatCannotClearTheFilesSaysSoAndClearsThemOnceItCan() throws {
        let index = try makeIndex()
        try index.db.execute("PRAGMA busy_timeout = 150")
        try transcript(index, of: nil, "codename zebraquokka7781 ships in june")
        let reader = try Database(path: root.appendingPathComponent("index.sqlite").path, readOnly: true)
        try reader.execute("BEGIN")
        try reader.query("SELECT count(*) FROM chunks")

        XCTAssertThrowsError(try index.purge(meeting: meeting, folder: folder, roots: [meetingRoot]),
                             "the text could not be cleared from the files, so the purge must not report success")
        XCTAssertEqual(try hits("zebraquokka7781", in: index), 0, "it is out of the tables either way")
        XCTAssertTrue(onDisk("zebraquokka7781"), "and still in the files, which is why this is not yet a purge")

        try reader.execute("COMMIT")
        try index.purge(meeting: meeting, folder: folder, roots: [meetingRoot])     // the retention loop's next round
        XCTAssertFalse(onDisk("zebraquokka7781"), "gone from the database and from its write-ahead log")
    }
}
