import AppKit
import CoreML
import ImageIO
import UniformTypeIdentifiers
import XCTest
import WorkScribeCore
@testable import WorkScribe

private actor ReadCounter {
    var count = 0
    func read() async -> (String, [ScreenTextLine]) { count += 1; return ("Dashboard revenue overview", []) }
}
@MainActor final class ScreenSceneTextTests: XCTestCase {
    func fixture() throws -> (URL, MeetingStore, Meeting, ScreenMoment) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = MeetingStore(root: root)
        var meeting = Meeting(title: "Scene test"); meeting.status = "complete"
        meeting.screen = ScreenCaptureInfo(state: "complete", momentCount: 1)
        try store.save(meeting)
        var scene = ScreenMoment(start: 0, end: 20, text: "")
        scene.keyframe = ScreenFiles.keyframe(scene.id); scene.representativeTime = 5
        scene.embedding = [1] + Array(repeating: 0, count: 767); scene.embeddingModelID = "fixture"
        try store.saveScreenMoments([scene], id: meeting.id)
        let url = try store.directory(meeting.id).appendingPathComponent(scene.keyframe!)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let image = ScreenVerification.renderSlide()
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        return (root,store,meeting,scene)
    }
    func testTransientFrameOCRLeavesOnlyTextOnDisk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        var meeting = Meeting(title: "Transient OCR"); meeting.status = "complete"
        meeting.screen = ScreenCaptureInfo(state: "complete")
        try store.save(meeting)
        var scene = ScreenMoment(start: 0, end: 10, text: "")
        scene.representativeTime = 1
        try store.saveScreenMoments([scene], id: meeting.id)
        let reader = ScreenSceneText(reader: { _ in ("Only derived text", []) })
        let result = await reader.read(scene.id, meetingID: meeting.id, store: store, image: ScreenVerification.renderSlide())
        XCTAssertEqual(result?.text, "Only derived text")
        XCTAssertNil(result?.keyframe); XCTAssertNil(result?.thumbnail)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: store.directory(meeting.id).path)),
                       ["transcript.json", "screen-moments.json"])
    }

    func testVisionPreprocessingUsesPinnedFloat16PositionContract() throws {
        let (features, count) = try EmbeddingGemmaVision.preprocess(ScreenVerification.renderSlide(), positions: Data(repeating: 0, count: 2*1024*768*2))
        XCTAssertLessThanOrEqual(count, 70)
        XCTAssertGreaterThan(count, 0)
        let positions = try XCTUnwrap(features.featureValue(for: "positions")?.multiArrayValue)
        XCTAssertEqual(positions.dataType, .float16)
        XCTAssertEqual(positions.shape.map(\.intValue), [1,630,2])
    }
    func testLazyUntilAllowedThenExactlyOneReadAcrossRequests() async throws {
        let (root,store,meeting,scene) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let counter = ReadCounter(), reader = ScreenSceneText(reader: { _ in await counter.read() })
        let denied = await reader.read(scene.id, meetingID: meeting.id, store: store, allowed: { false })
        XCTAssertNil(denied)
        XCTAssertEqual(store.loadScreenMoments(meeting.id).first?.text, "")
        let first = await reader.read(scene.id, meetingID: meeting.id, store: store)
        let second = await reader.read(scene.id, meetingID: meeting.id, store: store)
        XCTAssertEqual(first?.text, "Dashboard revenue overview"); XCTAssertNil(second)
        let calls = await counter.count; XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.loadScreenMoments(meeting.id).first?.ocrState, "complete")
    }
    func testPurgeWhileOCRInFlightNeverRecreatesFilesOrVectors() async throws {
        let (root,store,meeting,scene) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let index = try SearchIndex(url: root.appendingPathComponent("index.sqlite"))
        try await MeetingIndexer(index: index, embedder: nil).index(meeting, screen: [scene], folder: try store.directory(meeting.id))
        XCTAssertEqual(try index.vectorStats().count, 1)
        let receipts = RetentionStore(meetings: store)
        try receipts.save(RetentionReceipt(meeting, vaultPath: root.appendingPathComponent("note.md").path))
        let begun = expectation(description: "OCR started")
        let reader = ScreenSceneText(reader: { _ in
            begun.fulfill(); try? await Task.sleep(nanoseconds: 150_000_000); return ("Private dashboard", [])
        })
        let task = Task { await reader.read(scene.id, meetingID: meeting.id, store: store) }
        await fulfillment(of: [begun], timeout: 2)
        try receipts.purge(meeting.id, meetings: store, conversations: ConversationStore(root: root.appendingPathComponent("Chats")), index: index)
        let result = await task.value
        XCTAssertNil(result); XCTAssertTrue(store.loadScreenMoments(meeting.id).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.directory(meeting.id).path))
        XCTAssertEqual(try index.vectorStats().count, 0)
    }


}
