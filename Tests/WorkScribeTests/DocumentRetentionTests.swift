import XCTest
import WorkScribeCore
@testable import WorkScribe

private struct NoDocumentEnhancement: NoteEnhancing {
    func enhance(_ meeting: Meeting, incremental: Bool, missedTopics: Bool) async throws -> NoteDraft? { nil }
}

@MainActor final class DocumentRetentionTests: XCTestCase {
    func testDeadlinePurgesRawDespiteClosedEditorChangesOrDeletedNote() async throws {
        let old = NoteEnhancementScheduler.shared.enhancer
        NoteEnhancementScheduler.shared.enhancer = NoDocumentEnhancement()
        defer { NoteEnhancementScheduler.shared.enhancer = old }
        for deleteFile in [false,true] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at:root) }
            let store=MeetingStore(root:root.appendingPathComponent("Meetings"))
            let vault=VaultStore(root:root.appendingPathComponent("Vault"),stateDirectory:root.appendingPathComponent("State"))
            var meeting=Meeting(title:"Fixture");meeting.endedAt=Date().addingTimeInterval(-90000);meeting.status="complete"
            var doc=try vault.openDocument(meeting);doc.source += "my original words\n"
            let from=(doc.source as NSString).range(of:"my original words").location
            doc.blocks=[.init(id:"a",from:from,to:from+17,text:"my original words")]
            meeting.document=doc;meeting.notes=doc.notes(previous:[])
            let file=URL(fileURLWithPath:doc.path)
            if deleteFile { try FileManager.default.removeItem(at:file) }
            else { try (doc.source+"\nAdded while closed\n").write(to:file,atomically:true,encoding:.utf8) }
            try store.save(meeting)
            let model=AppModel(store:store)
            let ask=AskService(model:model,store:ConversationStore(root:root.appendingPathComponent("Conversations")),generator:nil)
            let retention=MeetingRetention(model:model,ask:ask,vault:vault,index:nil,requiresIndex:false)
            await retention.recover()
            XCTAssertEqual(try RetentionStore(meetings:store).load(meeting.id)?.state,"purged")
            XCTAssertFalse(FileManager.default.fileExists(atPath:try store.directory(meeting.id).path))
            if deleteFile { XCTAssertFalse(FileManager.default.fileExists(atPath:file.path)) }
            else { XCTAssertTrue(try String(contentsOf:file,encoding:.utf8).contains("Added while closed")) }
        }
    }
}

extension DocumentRetentionTests {
    func testNativePencilWaitsUntilTwentyThreeHoursAndMarkersFade() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=MeetingStore(root:root.appendingPathComponent("Meetings"))
        let vault=VaultStore(root:root.appendingPathComponent("Vault"),stateDirectory:root.appendingPathComponent("State"))
        var meeting=Meeting(title:"Timing fixture");meeting.endedAt=Date().addingTimeInterval(-82_000);meeting.status="complete";meeting.retention="live"
        var doc=try vault.openDocument(meeting)
        doc.source += "\n<!-- workscribe:begin notes -->\nMy words\n<!-- workscribe:end notes abc -->\n"
        try doc.source.write(toFile:doc.path,atomically:true,encoding:.utf8)
        meeting.document=doc;try store.save(meeting)
        let model=AppModel(store:store)
        let ask=AskService(model:model,store:ConversationStore(root:root.appendingPathComponent("Conversations")),generator:nil)
        let retention=MeetingRetention(model:model,ask:ask,vault:vault,index:nil,requiresIndex:false)
        await retention.recover()
        XCTAssertEqual(try store.load(meeting.id).document?.finalized,false)
        meeting.endedAt=Date().addingTimeInterval(-83_000);try store.save(meeting)
        await retention.recover()
        XCTAssertEqual(try store.load(meeting.id).document?.finalized,true)
        XCTAssertTrue(FileManager.default.fileExists(atPath:try store.directory(meeting.id).path))
        try await retention.done(meeting.id)
        let final=try String(contentsOfFile:doc.path,encoding:.utf8)
        XCTAssertTrue(final.contains("My words"));XCTAssertFalse(final.contains("<!-- workscribe:"))
    }
}
