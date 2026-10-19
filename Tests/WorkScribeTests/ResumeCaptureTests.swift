import XCTest
import AVFoundation
import WorkScribeCore
@testable import WorkScribe

@MainActor final class ResumeCaptureTests: XCTestCase {
    func testResumedCaptureLeavesNoMedia() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        var meeting = Meeting(title: "Resume"); meeting.status = "complete"; meeting.endedAt = Date()
        try store.save(meeting)
        for _ in 0..<2 {
            let track = AudioTrack()
            let buffer = AVAudioPCMBuffer(pcmFormat: track.format, frameCapacity: 1600)!
            buffer.frameLength = 1600
            track.accept(buffer); track.finish()
            try meeting.resume(); meeting.status = "complete"; meeting.endedAt = Date()
            try store.save(meeting)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: store.directory(meeting.id).path)
        XCTAssertEqual(files, ["transcript.json"])
    }

    func testResumedMeetingIgnoresOldPurgeDeadlineAndRestartsOnStop() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=MeetingStore(root:root.appendingPathComponent("Meetings"))
        let vault=VaultStore(root:root.appendingPathComponent("Vault"),stateDirectory:root.appendingPathComponent("State"))
        var meeting=Meeting(title:"Retention on resume");meeting.status="complete";meeting.endedAt=Date()
        meeting.document=try vault.openDocument(meeting)
        try store.save(meeting)
        var receipt=RetentionReceipt(meeting,vaultPath:meeting.document!.path)
        receipt.purgeAt=Date().addingTimeInterval(-1)
        try RetentionStore(meetings:store).save(receipt)
        try meeting.resume();try store.save(meeting)
        let model=AppModel(store:store);model.meeting=meeting;model.phase="recording"
        let ask=AskService(model:model,store:ConversationStore(root:root.appendingPathComponent("Conversations")),generator:nil)
        let retention=MeetingRetention(model:model,ask:ask,vault:vault,index:nil,requiresIndex:false)
        model.retentionService=retention
        let previous=NoteEnhancementScheduler.shared.enhancer
        NoteEnhancementScheduler.shared.enhancer=NoResumeEnhancement()
        defer { NoteEnhancementScheduler.shared.enhancer=previous }
        await retention.recover()
        XCTAssertTrue(FileManager.default.fileExists(atPath:try store.directory(meeting.id).path))
        await model.stop()
        let restarted=try XCTUnwrap(RetentionStore(meetings:store).load(meeting.id))
        XCTAssertGreaterThan(restarted.purgeAt.timeIntervalSinceNow,86390)
        XCTAssertNotNil(model.meeting?.endedAt)
        XCTAssertEqual(model.meeting?.id,meeting.id)
    }

    func testFinalPassFromEarlierCaptureCannotOverwriteResumedNote() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let model=AppModel(store:MeetingStore(root:root))
        var meeting=Meeting(title:"Delayed final pass");meeting.status="complete";meeting.endedAt=Date()
        meeting.notes=[Note(text:"release",createdAt:2)]
        meeting.segments=[Segment(source:"system",speaker:"system:speaker-1",start:1,end:3,text:"Release ships Friday.")]
        model.meeting=meeting;model.phase="finalizing"
        let enhancer=SuspendedResumeEnhancer(),scheduler=NoteEnhancementScheduler();scheduler.enhancer=enhancer
        let task=Task { await scheduler.finish(meeting.id,model:model) }
        while !(await enhancer.waiting) { await Task.yield() }
        try model.meeting!.resume()
        model.phase="recording"
        await enhancer.release()
        await task.value
        XCTAssertNil(model.meeting?.notes?.first?.line.text)
        XCTAssertNil(model.meeting?.endedAt)
    }
}

private actor SuspendedResumeEnhancer: Enriching {
    var waiting=false
    private var continuation: CheckedContinuation<Void,Never>?
    func enhance(_ meeting:Meeting,incremental:Bool) async throws -> Enrichment? {
        waiting=true
        await withCheckedContinuation { continuation=$0 }
        return Enrichment.fixture(plan:try SelectionFixture.plan(meeting,incremental:false),output:"* **Release:** Old final pass ships Friday.")
    }
    func release() { continuation?.resume();continuation=nil }
}

private struct NoResumeEnhancement: Enriching {
    func enhance(_ meeting:Meeting,incremental:Bool) async throws -> Enrichment? { nil }
}
