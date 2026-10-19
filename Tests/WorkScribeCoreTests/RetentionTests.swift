import XCTest
@testable import WorkScribeCore

final class RetentionTests: XCTestCase {
    func testPurgeCrashReplayRemovesAllRawDataAndPreservesNotesAndVoices() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ws-retention-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root.appendingPathComponent("Meetings"))
        let conversations = ConversationStore(root: root.appendingPathComponent("Conversations"))
        let vault = VaultStore(root: root.appendingPathComponent("Notes"), stateDirectory: root.appendingPathComponent("Vault"))
        var meeting = Meeting(title: "Synthetic meeting")
        meeting.endedAt = Date(); meeting.status = "complete"
        meeting.segments = [Segment(source: "microphone", speaker: "one", start: 0, end: 3, text: "rawsentineluniquexyz")]
        var note = Note(text: "  ship Nov 4  ", createdAt: 2)
        note.line.text = "**Ship:** Release November 4."; note.line.evidence = [meeting.segments[0].id + "#0"]
        meeting.notes = [note]; meeting.retention = "finalized"; meeting.purgeAt = .distantPast
        try store.save(meeting)
        let folder = try store.directory(meeting.id)
        for name in ["microphone.wav", "system.wav", "screen.mov", "screen/moment.jpg", "attachments/a.pdf", "screen.json"] {
            let file = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("rawsentineluniquexyz".utf8).write(to: file)
        }
        let voice = store.root.appendingPathComponent("voices.json")
        try Data("voice-profile".utf8).write(to: voice)
        let out = try vault.writeMeeting(meeting)
        let url = vault.url(out.path)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(note.text)); XCTAssertTrue(text.contains(note.line.text!))
        XCTAssertFalse(text.contains("workscribe://")); XCTAssertFalse(text.contains("^e1"))
        let index = try SearchIndex(url: root.appendingPathComponent("index.sqlite"))
        let vector = Array(repeating: Float(0.1), count: 768)
        try index.replace(kind: .meeting, ref: meeting.id, title: meeting.title, fingerprint: "fixture", modelID: "fake",
                          chunks: [Chunk(kind: .meetingSegment, modality: .text, text: "rawsentineluniquexyz", vector: vector)])
        XCTAssertEqual(try index.vectorStats().count, 1)
        var conversation = Conversation(scopeMeetingID: meeting.id)
        conversation.messages = [AskMessage(role: .assistant, text: "rawsentineluniquexyz")]
        try conversations.save(conversation)
        try index.replace(kind: .file, ref: root.appendingPathComponent("attachment.md").path,
                          root: AttachmentOwner.conversation(conversation.id).indexRoot,
                          title: "Attachment", fingerprint: "fixture", modelID: "fake",
                          chunks: [Chunk(kind: .document, modality: .text, text: "rawsentineluniquexyz", vector: vector)])
        let retention = RetentionStore(meetings: store)
        var receipt = RetentionReceipt(meeting, vaultPath: url.path)
        receipt.state = "purging" // Simulated crash after persisting the deletion intent.
        try retention.save(receipt)
        XCTAssertEqual(try store.load(meeting.id).segments.count, 0)
        try retention.purge(meeting.id, meetings: store, conversations: conversations, index: index)
        try retention.purge(meeting.id, meetings: store, conversations: conversations, index: index)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(conversations.list().count, 0)
        XCTAssertEqual(try index.vectorStats().count, 0)
        XCTAssertNil(try index.source(ref: meeting.id))
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let file as URL in files where file.pathExtension != "md" {
            guard let data = try? Data(contentsOf: file) else { continue }
            XCTAssertNil(data.range(of: Data("rawsentineluniquexyz".utf8)), file.path)
        }
        XCTAssertEqual(try store.load(meeting.id).retention, "purged")
        XCTAssertEqual(try String(contentsOf: voice, encoding: .utf8), "voice-profile")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
        XCTAssertThrowsError(try store.save(meeting), "An in-flight writer cannot resurrect raw data")
        let reopened = try SearchIndex(url: root.appendingPathComponent("index.sqlite"))
        XCTAssertEqual(try reopened.vectorStats().count, 0)
    }
    func testPreviouslyFinalizedMeetingStillPurgesIfUserRemovedVaultNote() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root.appendingPathComponent("Meetings"))
        var meeting = Meeting(title: "Deleted note"); meeting.endedAt = Date(); meeting.status = "complete"
        try store.save(meeting)
        let journal = RetentionStore(meetings: store)
        try journal.save(RetentionReceipt(meeting, vaultPath: root.appendingPathComponent("removed-note.md").path))
        try journal.purge(meeting.id, meetings: store, conversations: ConversationStore(root: root.appendingPathComponent("Conversations")), index: nil)
        XCTAssertEqual(try journal.load(meeting.id)?.state, "purged")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.directory(meeting.id).path))
    }


}

extension RetentionTests {
    func testUncitedTraceSourcesAreScrubbedWithTheirMeeting() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let meetings=MeetingStore(root:root.appendingPathComponent("Meetings"))
        let conversations=ConversationStore(root:root.appendingPathComponent("Conversations"))
        var meeting=Meeting(title:"Trace fixture");meeting.endedAt=Date();try meetings.save(meeting)
        var answer=AskMessage(role:.assistant,text:"A source-derived answer")
        var trace=AITrace();trace.sources=[TraceSource(kind:"meeting",title:"Private fixture",text:"raw-trace-sentinel",link:"workscribe://meeting/"+meeting.id)]
        answer.trace=trace
        var conversation=Conversation();conversation.messages=[answer];try conversations.save(conversation)
        let retention=RetentionStore(meetings:meetings)
        try retention.save(RetentionReceipt(meeting,vaultPath:root.appendingPathComponent("note.md").path))
        try retention.purge(meeting.id,meetings:meetings,conversations:conversations,index:nil)
        let saved=try XCTUnwrap(conversations.list().first)
        XCTAssertNil(saved.messages[0].trace);XCTAssertEqual(saved.messages[0].text,"Meeting source deleted.")
    }
}
