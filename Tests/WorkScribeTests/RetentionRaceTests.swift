import XCTest
import WorkScribeCore
@testable import WorkScribe

/// Counterexamples from `formal/tla/Retention.tla`, replayed on the real `MeetingRetention`,
/// `RetentionStore` and `MeetingStore`. The comment on each test gives the property it violates.
@MainActor final class RetentionRaceTests: XCTestCase {
    private struct NoEnhancement: Enriching {
        func enhance(_ meeting: Meeting, incremental: Bool) async throws -> Enrichment? { nil }
    }
    private var root: URL!
    private var previous: (any Enriching)!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("retention-" + UUID().uuidString)
        previous = NoteEnhancementScheduler.shared.enhancer
        NoteEnhancementScheduler.shared.enhancer = NoEnhancement()
    }
    override func tearDown() async throws {
        NoteEnhancementScheduler.shared.enhancer = previous
        try? FileManager.default.removeItem(at: root)
    }

    private struct World { let store: MeetingStore; let vault: VaultStore; let model: AppModel; let retention: MeetingRetention; let receipts: RetentionStore }
    private func world() -> World {
        let store = MeetingStore(root: root.appendingPathComponent("Meetings"))
        let vault = VaultStore(root: root.appendingPathComponent("Vault"), stateDirectory: root.appendingPathComponent("State"))
        let model = AppModel(store: store)
        let ask = AskService(model: model, store: ConversationStore(root: root.appendingPathComponent("Conversations")), generator: nil)
        let retention = MeetingRetention(model: model, ask: ask, vault: vault, index: nil, requiresIndex: false)
        model.retentionService = retention
        return World(store: store, vault: vault, model: model, retention: retention, receipts: RetentionStore(meetings: store))
    }
    private func ended(_ title: String, ago: TimeInterval) -> Meeting {
        var meeting = Meeting(title: title)
        meeting.status = "complete"; meeting.endedAt = Date().addingTimeInterval(-ago)
        meeting.segments = [Segment(source: "system", speaker: "system:speaker-1", start: 1, end: 3, text: "The launch moves to the ninth.")]
        meeting.notes = [Note(text: "launch date", createdAt: 2)]
        return meeting
    }

    /// T5 (a), "eventually purged": a finalized meeting moved to the Trash kept its receipt, and the purge
    /// loop read "cannot load it" as "still recording" and skipped it for ever.
    func testAFinalizedMeetingMovedToTheTrashIsStillPurgedAtItsDeadline() async throws {
        let w = world()
        var meeting = ended("Trashed", ago: 90_000)
        meeting.retention = "finalized"; meeting.purgeAt = Date().addingTimeInterval(-3_600)
        try w.store.save(meeting)
        try w.receipts.save(RetentionReceipt(meeting, vaultPath: root.appendingPathComponent("Vault/Trashed.md").path))
        try FileManager.default.removeItem(at: w.store.directory(meeting.id))      // what "Move to Trash" leaves behind
        await w.retention.recover()
        XCTAssertEqual(try w.receipts.load(meeting.id)?.state, "purged", "its deadline passed; nothing may keep it pending")
    }

    /// The same meeting's rows must leave the search index as soon as it is trashed, not stay findable
    /// until the deadline: the store lists a stand-in for its receipt, which the indexer took for the meeting.
    func testATrashedMeetingsRowsLeaveTheIndex() async throws {
        let w = world()
        var meeting = ended("Trashed but searchable", ago: 600)
        meeting.retention = "finalized"; meeting.purgeAt = Date().addingTimeInterval(80_000)
        try w.store.save(meeting)
        try w.receipts.save(RetentionReceipt(meeting, vaultPath: root.appendingPathComponent("Vault/T.md").path))
        let index = try SearchIndex(url: root.appendingPathComponent("index.sqlite"))
        let indexer = MeetingIndexer(index: index, embedder: nil)
        _ = try await indexer.sync(store: w.store)
        XCTAssertFalse(try index.search(SearchRequest("launch")).hits.isEmpty, "indexed while it exists")
        try FileManager.default.removeItem(at: w.store.directory(meeting.id))
        XCTAssertTrue(w.store.list().contains { $0.id == meeting.id }, "the receipt still stands in for it in the list")
        _ = try await indexer.sync(store: w.store)
        XCTAssertTrue(try index.search(SearchRequest("launch")).hits.isEmpty, "a trashed meeting is not searchable")
    }

    /// T7 and T5 (d): Stop, Resume, then the app dies. The receipt from the first Stop is still on disk with
    /// its deadline. The purge loop used it: it deleted the second session without ever writing it to the
    /// note, and on the first Stop's clock.
    func testAResumedThenInterruptedMeetingIsFinalizedAgainBeforeAnyPurge() async throws {
        let w = world()
        // First stop, a day ago; finalized then.
        var meeting = ended("Two sessions", ago: 90_000)
        var first = meeting; first.retention = "finalized"; first.purgeAt = first.endedAt!.addingTimeInterval(86_400)
        try w.store.save(first)
        try w.receipts.save(RetentionReceipt(first, vaultPath: w.vault.url("Two sessions.md").path))
        // Resumed, recorded more, then the app died; relaunch marked it interrupted an hour ago.
        meeting.retention = "live"; meeting.status = "interrupted"
        meeting.endedAt = Date().addingTimeInterval(-3_600); meeting.purgeAt = meeting.endedAt!.addingTimeInterval(86_400)
        meeting.segments.append(Segment(source: "system", speaker: "system:speaker-1", start: 400, end: 404, text: "Second session: budget approved."))
        try w.store.save(meeting)
        XCTAssertLessThan(try XCTUnwrap(w.receipts.load(meeting.id)).purgeAt, Date(), "the stale receipt's deadline has passed")

        await w.retention.recover()

        let receipt = try XCTUnwrap(w.receipts.load(meeting.id))
        XCTAssertNotEqual(receipt.state, "purged", "the meeting's own deadline is a day after its LAST stop")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try w.store.directory(meeting.id).path), "the second session's transcript is still there")
        XCTAssertEqual(try w.store.load(meeting.id).retention, "finalized", "and it was finalized again, so the note has the second session")
        XCTAssertGreaterThan(receipt.purgeAt.timeIntervalSinceNow, 80_000, "on the second stop's clock")
    }

    /// T4, "no regression": Done has journalled "purging" and is in the middle of deleting when a Finalize
    /// arrives. Finalize looked only at the copy of the meeting in memory and wrote "finalized" over the journal.
    func testFinalizeNeverOverwritesAPurgeInProgress() async throws {
        let w = world()
        var meeting = ended("Being purged", ago: 600)
        meeting.retention = "finalized"; meeting.purgeAt = Date().addingTimeInterval(80_000)
        try w.store.save(meeting)
        try w.receipts.save(RetentionReceipt(meeting, vaultPath: w.vault.url("Being purged.md").path))
        w.model.meeting = meeting                                   // still the meeting on screen

        var regressed = false
        let purging = Task { try await w.retention.done(meeting.id) }
        // The moment the journal says "purging", a Finalize comes in.
        for _ in 0..<10_000 where try w.receipts.load(meeting.id)?.state == "finalized" { await Task.yield() }
        try XCTSkipUnless(try w.receipts.load(meeting.id)?.state == "purging", "the window inside Done was not hit on this run")
        try await w.retention.finalize(meeting.id)
        regressed = try w.receipts.load(meeting.id)?.state == "finalized"
        try await purging.value
        XCTAssertFalse(regressed, "a purge that has been journalled is never turned back into 'finalized'")
        XCTAssertEqual(try w.receipts.load(meeting.id)?.state, "purged")
    }

    /// T5, "an interrupted purge is replayed": Done journalled "purging" and was cut short; meanwhile the note
    /// was opened again, so the copy of the meeting in memory has an unfinalized document. Every later round
    /// then tried to finalize first, was turned away because the journal says purging, and gave up, leaving
    /// the transcript on disk. Introduced by the T7 re-check; found when the model was run against it.
    func testAnInterruptedPurgeIsCarriedOutEvenIfTheNoteWasReopenedInMemory() async throws {
        let w = world()
        var meeting = ended("Interrupted purge", ago: 90_000)
        meeting.retention = "finalized"; meeting.purgeAt = Date().addingTimeInterval(-3_600)
        meeting.document = NoteDocument(path: w.vault.url("Interrupted purge.md").path, source: "# Interrupted purge\n", finalized: true)
        try w.store.save(meeting)
        var receipt = RetentionReceipt(meeting, vaultPath: w.vault.url("Interrupted purge.md").path)
        receipt.state = "purging"
        try w.receipts.save(receipt)
        meeting.document?.finalized = false                         // the undo changed this copy; its save was refused
        w.model.meeting = meeting

        await w.retention.recover()

        XCTAssertEqual(try w.receipts.load(meeting.id)?.state, "purged", "a journalled purge is carried out, not turned away")
        XCTAssertFalse(w.store.hasTranscript(meeting.id), "and the transcript is gone")
    }

    /// `Gone` (`formal/tla/IndexPurge.tla`): a question asked from the meeting's page while its index rows are
    /// being deleted starts a conversation scoped to it. That conversation's files were deleted with all the
    /// others; what had been indexed for it was not, because the index had been told which conversations to
    /// purge before it existed.
    func testAConversationStartedWhileTheIndexIsBeingPurgedGoesWithTheMeeting() async throws {
        let store = MeetingStore(root: root.appendingPathComponent("Meetings"))
        let vault = VaultStore(root: root.appendingPathComponent("Vault"), stateDirectory: root.appendingPathComponent("State"))
        let model = AppModel(store: store)
        let ask = AskService(model: model, store: ConversationStore(root: root.appendingPathComponent("Conversations")), generator: nil)
        let search = try SearchIndex(url: root.appendingPathComponent("index.sqlite"))
        let retention = MeetingRetention(model: model, ask: ask, vault: vault, index: IndexService(index: search, store: store, embedder: nil))
        var meeting = ended("Asked about while it was purged", ago: 90_000)
        meeting.retention = "finalized"; meeting.purgeAt = Date().addingTimeInterval(-3_600)
        try store.save(meeting)
        try RetentionStore(meetings: store).save(RetentionReceipt(meeting, vaultPath: root.appendingPathComponent("Vault/Asked.md").path))

        var late: String?
        retention.afterIndexPass = { [root] in
            guard late == nil else { return }
            let id = ask.ensureConversation(nil)
            ask.setScope(id, meetingID: meeting.id)
            late = id
            try? search.replace(kind: .file, ref: root!.appendingPathComponent("Conversations/\(id)/attachments/asked.md").path,
                                root: AttachmentOwner.conversation(id).indexRoot, title: "asked.md", fingerprint: "1", modelID: nil,
                                chunks: [Chunk(kind: .document, modality: .text, text: "numbatsecret from the call")])
        }
        try await retention.done(meeting.id)

        let id = try XCTUnwrap(late, "the conversation was started during the purge")
        XCTAssertEqual(try RetentionStore(meetings: store).load(meeting.id)?.state, "purged")
        XCTAssertNil(ask.conversation(id), "the conversation is deleted with the meeting")
        XCTAssertTrue(try search.search(SearchRequest("numbatsecret")).hits.isEmpty, "and so is what was indexed for it")
        XCTAssertTrue(try RetentionStore(meetings: store).load(meeting.id)?.conversationIDs?.contains(id) == true,
                      "the journal names it, so a purge cut short here would still delete it")
    }
}
