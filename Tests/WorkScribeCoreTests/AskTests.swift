import XCTest
@testable import WorkScribeCore

final class AskTests: XCTestCase {
    var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ask-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func moment(_ id: String, ref: String = "m1", start: Double? = nil, page: Int? = nil, meeting: Bool = true, text: String = "x") -> AskMoment {
        AskMoment(id: id, sourceKind: meeting ? "meeting" : "file", ref: ref, title: meeting ? "Standup" : nil,
                  kind: meeting ? "meetingSegment" : "document", start: start, page: page, speakers: meeting ? ["Priya"] : [], text: text)
    }

    // MARK: Citation mapping

    func testCitationsAreRenumberedByFirstUseAndInvalidOnesDropped() {
        let moments = [moment("a"), moment("b"), moment("c")]
        let result = CitationMapper.map("Nov 4 is the date [3]. Priya owns it [1, 3] and [9]. Done [2][2].", moments: moments)
        XCTAssertEqual(result.text, "Nov 4 is the date [1]. Priya owns it [2][1] and. Done [3].")
        XCTAssertEqual(result.citations.map(\.number), [1, 2, 3])
        XCTAssertEqual(result.citations.map(\.moment.id), ["c", "a", "b"])
    }

    func testAnswerWithoutMarkersHasNoCitations() {
        let result = CitationMapper.map("The sources don't say.", moments: [moment("a")])
        XCTAssertEqual(result.text, "The sources don't say.")
        XCTAssertTrue(result.citations.isEmpty)
        XCTAssertEqual(CitationMapper.momentsOnly([moment("a"), moment("b")]).map(\.number), [1, 2])
    }

    func testPiecesSplitTextAroundMarkers() {
        XCTAssertEqual(CitationMapper.pieces("A [1]. B[2]"), [.text("A "), .citation(1), .text(". B"), .citation(2)])
    }

    func testMomentLinksOpenMeetingAtTimeOrFileAtPage() {
        var m = moment("a", ref: "11111111-1111-1111-1111-111111111111", start: 1650)
        m.anchorSegment = "seg"
        XCTAssertEqual(m.link, .meeting(id: "11111111-1111-1111-1111-111111111111", seconds: 1650, segment: "seg"))
        XCTAssertEqual(m.locator, "Priya · 27:30")
        let file = moment("b", ref: "/tmp/MSA.pdf", page: 14, meeting: false)
        XCTAssertEqual(file.link, .file(path: "/tmp/MSA.pdf", page: 14, seconds: nil))
        XCTAssertEqual(file.sourceName, "MSA.pdf")
        XCTAssertEqual(file.locator, "p.14")
    }

    // MARK: Prompt and retrieval

    func testPromptNumbersSourcesWithinBudget() {
        let long = String(repeating: "word ", count: 400)
        let prompt = AskPrompt.build(question: " What moved? ", moments: [moment("a", text: long), moment("b", text: "short"), moment("c", text: long)],
                                     perSource: 100, budget: 260)
        XCTAssertEqual(prompt.moments.map(\.id), ["a", "b"])
        XCTAssertTrue(prompt.sources.hasPrefix("[1] Standup · Priya"))
        XCTAssertTrue(prompt.sources.contains("[2] Standup"))
        XCTAssertEqual(prompt.question, "What moved?")
        XCTAssertTrue(prompt.userText.hasSuffix("Question: What moved?"))
    }

    func testMergePutsAttachedFirstAndDeduplicates() {
        let attached = [moment("p1", ref: "/a.pdf", page: 1, meeting: false), moment("p2", ref: "/a.pdf", page: 2, meeting: false),
                        moment("p3", ref: "/a.pdf", page: 3, meeting: false)]
        let general = [moment("g1", start: 10), moment("p1", ref: "/a.pdf", page: 1, meeting: false), moment("g2", start: 10.4), moment("g3", start: 50)]
        let merged = AskRetrieval.merge(priority: attached, general: general, limit: 5, priorityShare: 2)
        // g2 is the same place as g1 (same meeting, same second); p3 fills the room left.
        XCTAssertEqual(merged.map(\.id), ["p1", "p2", "g1", "g3", "p3"])
    }

    func testLiveMomentsMatchWordsOrFallBackToLatest() {
        var meeting = Meeting(title: "Live")
        meeting.segments = [
            Segment(source: "system", speaker: "system:speaker-1", start: 0, end: 10, text: "The Halvorsen contract requires offline capture by December."),
            Segment(source: "system", speaker: "system:speaker-2", start: 10, end: 20, text: "Lunch is at noon on Friday."),
            Segment(source: "system", speaker: "system:speaker-1", start: 20, end: 30, text: "Marcus will prototype the merge."),
        ]
        let hits = AskRetrieval.liveMoments(question: "what does the contract require?", meeting: meeting, limit: 2)
        XCTAssertEqual(hits.first?.anchorSegment, meeting.segments[0].id)
        XCTAssertTrue(hits.allSatisfy { $0.attached && $0.ref == meeting.id })
        let latest = AskRetrieval.liveMoments(question: "zzz", meeting: meeting, limit: 1)
        XCTAssertEqual(latest.first?.anchorSegment, meeting.segments[2].id)
    }

    // MARK: Conversations and attachments

    func testConversationStoreRoundTripsAndListsNewestFirst() throws {
        let store = ConversationStore(root: folder)
        var older = Conversation(title: "Older"); older.updatedAt = Date(timeIntervalSince1970: 1_000)
        var newer = Conversation(title: "Newer", pinned: true)
        newer.messages = [AskMessage(role: .user, text: "Q"),
                          AskMessage(role: .assistant, text: "A [1]", citations: [AskCitation(number: 1, moment: moment("a"))])]
        newer.attachments = [Attachment(kind: .note, name: "n", storedFile: "n.md")]
        try store.save(older); try store.save(newer)
        let listed = store.list()
        XCTAssertEqual(listed.map(\.title), ["Newer", "Older"])
        XCTAssertEqual(listed.first?.id, newer.id)
        XCTAssertEqual(listed.first?.messages.map(\.text), ["Q", "A [1]"])
        XCTAssertEqual(listed.first?.messages.last?.citations, newer.messages.last?.citations)
        XCTAssertEqual(listed.first?.attachments.map(\.storedFile), ["n.md"])
        XCTAssertEqual(listed.first?.pinned, true)
        XCTAssertThrowsError(try store.directory("../escape"))
    }

    func testConversationTitleIsShortenedAtAWord() {
        XCTAssertEqual(Conversation.title(for: "  short\nquestion "), "short question")
        let long = Conversation.title(for: String(repeating: "alpha ", count: 20))
        XCTAssertTrue(long.hasSuffix("…")); XCTAssertLessThanOrEqual(long.count, 61)
    }

    func testAttachmentsCopyFilesSaveNotesAndAvoidCollisions() throws {
        let source = folder.appendingPathComponent("report.pdf")
        try Data("pdf".utf8).write(to: source)
        let files = Attachments(folder: folder.appendingPathComponent("attachments"))
        let first = try files.addFile(source), second = try files.addFile(source)
        XCTAssertEqual(first.storedFile, "report.pdf"); XCTAssertEqual(second.storedFile, "report 2.pdf")
        XCTAssertEqual(first.originalPath, source.path); XCTAssertEqual(first.byteCount, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.url(of: second)!.path))
        let note = try files.addNote("Halvorsen: offline by Dec 31\nsync within 24h")
        XCTAssertEqual(note.kind, .note); XCTAssertEqual(note.name, "Halvorsen- offline by Dec 31".replacingOccurrences(of: "- ", with: ": "))
        XCTAssertEqual(files.noteText(note), "Halvorsen: offline by Dec 31\nsync within 24h")
        XCTAssertTrue(note.storedFile!.hasSuffix(".md")); XCTAssertFalse(note.storedFile!.contains(":"))
        files.remove(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.url(of: first)!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the original is never touched")
        XCTAssertThrowsError(try files.addNote("   "))
    }

    func testMeetingAttachmentSidecarRoundTrips() throws {
        let store = MeetingStore(root: folder)
        let meeting = Meeting(title: "M"); try store.save(meeting)
        let sidecar = MeetingAttachmentStore(store: store)
        XCTAssertEqual(sidecar.load(meeting.id), [])
        let note = try sidecar.files(meeting.id).addNote("agenda", title: "Agenda")
        try sidecar.save([note], for: meeting.id)
        XCTAssertEqual(sidecar.load(meeting.id).map(\.id), [note.id])
        XCTAssertEqual(sidecar.load(meeting.id).first?.storedFile, "Agenda.md")
        XCTAssertEqual(try store.load(meeting.id).title, "M")
    }

    // MARK: Index integration

    func testAttachmentSourcesSurviveFolderSyncAndScopeSearch() async throws {
        let index = try SearchIndex(url: folder.appendingPathComponent("index.sqlite"))
        let docs = folder.appendingPathComponent("docs"); try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try "The Acme invoice is overdue.".write(to: docs.appendingPathComponent("acme.txt"), atomically: true, encoding: .utf8)
        try index.addFolder(docs.path)
        let files = Attachments(folder: folder.appendingPathComponent("conv/attachments"))
        let note = try files.addNote("The Halvorsen invoice terms are net 30.", title: "Terms")
        let owner = AttachmentOwner.conversation(UUID().uuidString)
        let folders = FolderIndexer(index: index, embedder: nil)
        let state = await AttachmentIndexer(folders: folders).index(files.url(of: note)!, owner: owner)
        XCTAssertEqual(state, "indexed")
        _ = try await folders.sync()
        let refs = AttachmentIndexer.refs(in: index, owner: owner)
        XCTAssertEqual(refs, [files.url(of: note)!.path], "folder sync must not remove attachment sources")
        let all = try index.search(SearchRequest("invoice"))
        XCTAssertEqual(all.hits.count, 2)
        let scoped = try index.search(SearchRequest("invoice", sourceRefs: refs))
        XCTAssertEqual(scoped.hits.map(\.ref), [files.url(of: note)!.path])
        let odd = folder.appendingPathComponent("slides.key"); try Data([0, 1]).write(to: odd)
        let skipped = await AttachmentIndexer(folders: folders).index(odd, owner: owner)
        XCTAssertTrue(skipped.contains("unsupported"))
        files.remove(note)
        XCTAssertEqual(AttachmentIndexer.prune(index), 1)
    }

    // MARK: Open items and people

    func testOpenItemsComeFromMarkedNoteLines() {
        XCTAssertEqual(OpenItems.actionText("TODO: send checklist"), "send checklist")
        XCTAssertEqual(OpenItems.actionText("- [ ] review merge prototype"), "review merge prototype")
        XCTAssertEqual(OpenItems.actionText("AI - Priya emails Halvorsen"), "Priya emails Halvorsen")
        XCTAssertEqual(OpenItems.actionText("→ book room"), "book room")
        XCTAssertNil(OpenItems.actionText("- [x] done already"))
        XCTAssertNil(OpenItems.actionText("aim for nov 4"))
        var meeting = Meeting(title: "Scope")
        meeting.notes = [Note(text: "ship nov 4\ntodo update PRD", createdAt: 30)]
        let items = OpenItems.extract(from: [meeting])
        XCTAssertEqual(items.map(\.text), ["update PRD"])
        XCTAssertEqual(items.first?.link, .meeting(id: meeting.id, seconds: 30, segment: nil))
    }

    func testPeopleAreNamedSpeakersAcrossMeetings() {
        var a = Meeting(title: "A"); a.startedAt = Date(timeIntervalSince1970: 100)
        a.segments = [Segment(source: "system", speaker: "system:speaker-1", start: 0, end: 1, text: "hi")]
        a.speakerAssignments = ["system:speaker-1": SpeakerAssignment(name: "Priya")]
        var b = a; b.id = UUID().uuidString; b.startedAt = Date(timeIntervalSince1970: 200)
        let people = People.summarize([a, b], remembered: ["Marcus"])
        XCTAssertEqual(people.map(\.name), ["Priya", "Marcus"])
        XCTAssertEqual(people.first?.meetingIDs.count, 2)
    }
}
