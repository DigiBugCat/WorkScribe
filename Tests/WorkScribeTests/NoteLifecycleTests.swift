import XCTest
import WorkScribeCore
@testable import WorkScribe

private actor CountingEnhancer: NoteEnhancing {
    var calls: [(Bool, Int)] = []
    func enhance(_ meeting: Meeting, incremental: Bool, missedTopics: Bool) async throws -> NoteDraft? {
        let plan = try NotePlanner.plan(meeting, incremental: incremental, missedTopics: missedTopics)
        calls.append((incremental, plan.targets.count))
        return NoteDraft(plan: plan, output: "* **Release:** Friday.")
    }
}

@MainActor final class NoteLifecycleTests: XCTestCase {
    func testBurstIsCappedAndFinalPassVisitsAlreadyEnhancedNotes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: MeetingStore(root: root))
        var meeting = Meeting(title: "Fixture")
        meeting.notes = [Note(text: "release", createdAt: 2)]
        meeting.segments = [Segment(source: "mic", speaker: "one", start: 0, end: 3, text: "Release Friday")]
        model.meeting = meeting; model.phase = "recording"
        let scheduler = NoteEnhancementScheduler(), enhancer = CountingEnhancer()
        scheduler.enhancer = enhancer; scheduler.delay = 1_000_000; scheduler.minimumInterval = 10
        scheduler.schedule(meeting.id, model: model)
        for _ in 0..<200 {
            if !(await enhancer.calls).isEmpty { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let first = await enhancer.calls
        XCTAssertEqual(first.count, 1)
        for _ in 0..<20 { scheduler.schedule(meeting.id, model: model) }
        try await Task.sleep(nanoseconds: 30_000_000)
        let burst = await enhancer.calls
        XCTAssertEqual(burst.count, 1)
        await scheduler.finish(meeting.id, model: model)
        let final = await enhancer.calls
        XCTAssertEqual(final.count, 2)
        XCTAssertFalse(final.last!.0); XCTAssertEqual(final.last!.1, 1)
        XCTAssertEqual(model.meeting?.notes?.first?.text, "release")
    }

    func testFinalPassKeepsImageEvidenceWithoutTranscript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: MeetingStore(root: root))
        var meeting = Meeting(title: "Image-only fixture")
        var note = Note(text: "![[release.png]]", createdAt: 2)
        var image = NoteImage(target: "release.png")
        image.text = "Release Friday"; image.method = "vision-ocr"
        note.images = [image]
        meeting.notes = [note]
        model.meeting = meeting; model.phase = "recording"
        let scheduler = NoteEnhancementScheduler()
        scheduler.enhancer = CountingEnhancer()
        await scheduler.finish(meeting.id, model: model)
        let result = try XCTUnwrap(model.meeting?.notes?.first)
        XCTAssertNotNil(result.enhanced)
        XCTAssertTrue((result.excerptRefs ?? []).isEmpty)
        XCTAssertFalse(result.imageEvidence.isEmpty)
        XCTAssertNotNil(result.trace)
    }

    func testLaunchRecoveryFinishesAnInterruptedPurge() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root.appendingPathComponent("Meetings"))
        var meeting = Meeting(title: "Fixture")
        meeting.endedAt = Date(); meeting.status = "complete"; meeting.retention = "finalized"
        try store.save(meeting)
        let vault = VaultStore(root: root.appendingPathComponent("Notes"), stateDirectory: root.appendingPathComponent("Vault"))
        let result = try vault.writeMeeting(meeting)
        var receipt = RetentionReceipt(meeting, vaultPath: vault.url(result.path).path)
        receipt.state = "purging"; try RetentionStore(meetings: store).save(receipt)
        let model = AppModel(store: store)
        let ask = AskService(model: model, store: ConversationStore(root: root.appendingPathComponent("Conversations")), generator: nil)
        let service = MeetingRetention(model: model, ask: ask, vault: vault, index: nil, requiresIndex: false)
        await service.recover()
        XCTAssertEqual(try store.load(meeting.id).retention, "purged")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.directory(meeting.id).path))
    }
}
