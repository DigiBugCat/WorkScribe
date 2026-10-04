import XCTest
import WorkScribeCore
@testable import WorkScribe

actor ControlledTitleGenerator: TitleGenerating {
    private var result: CheckedContinuation<String, Error>?
    func generate(transcript: String) async throws -> String {
        try await withCheckedThrowingContinuation { result = $0 }
    }
    func waitForRequest() async { while result == nil { await Task.yield() } }
    func complete(_ title: String) { result?.resume(returning: title); result = nil }
    func fail() { result?.resume(throwing: CaptureError.message("Unavailable")); result = nil }
}

@MainActor
final class TitleLifecycleTests: XCTestCase {
    func fixture() throws -> (MeetingStore, Meeting) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = MeetingStore(root: root)
        var meeting = Meeting(title: "Recording", titleOrigin: "pending")
        meeting.status = "complete"
        meeting.segments = [Segment(source: "system", speaker: "1", start: 0, end: 6, text: "We are planning the desktop recorder release for Friday.")]
        try store.save(meeting)
        return (store, meeting)
    }
    func testLateGenerationPreservesManualRename() async throws {
        let (store, meeting) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        let generator = ControlledTitleGenerator()
        let model = AppModel(store: store, titleGenerator: generator)
        model.meeting = meeting
        model.scheduleTitle(id: meeting.id, final: true)
        await generator.waitForRequest()
        model.rename(id: meeting.id, to: "My exact title")
        await generator.complete("Automatically generated title")
        await model.prepareToQuit()
        XCTAssertEqual(try store.load(meeting.id).title, "My exact title")
        XCTAssertEqual(try store.load(meeting.id).titleOrigin, "manual")
    }
    func testOldTitleResultDoesNotReplaceCurrentMeeting() async throws {
        let (store, meeting) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        let generator = ControlledTitleGenerator()
        let model = AppModel(store: store, titleGenerator: generator)
        model.meeting = meeting
        model.scheduleTitle(id: meeting.id, final: true)
        await generator.waitForRequest()
        let next = Meeting(title: "Next recording", titleOrigin: "pending")
        model.meeting = next
        await generator.complete("Desktop Recorder Release")
        await model.prepareToQuit()
        XCTAssertEqual(model.meeting?.id, next.id)
        XCTAssertEqual(model.meeting?.title, "Next recording")
        XCTAssertEqual(try store.load(meeting.id).title, "Desktop Recorder Release")
        XCTAssertEqual(try store.load(meeting.id).segments.count, 1)
        XCTAssertEqual(try store.load(meeting.id).titleFinal, true)
    }
    func testGenerationFailureDoesNotLoseRecording() async throws {
        let (store, meeting) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        let generator = ControlledTitleGenerator()
        let model = AppModel(store: store, titleGenerator: generator)
        model.meeting = meeting
        model.scheduleTitle(id: meeting.id, final: true)
        await generator.waitForRequest()
        await generator.fail()
        await model.prepareToQuit()
        let saved = try store.load(meeting.id)
        XCTAssertEqual(saved.status, "complete")
        XCTAssertEqual(saved.segments.count, 1)
        XCTAssertEqual(saved.title, "Recording")
        XCTAssertNotNil(model.titleError[meeting.id])
    }
}
