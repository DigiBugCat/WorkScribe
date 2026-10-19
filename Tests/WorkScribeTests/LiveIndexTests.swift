import XCTest
import WorkScribeCore
@testable import WorkScribe

final class LiveIndexTests: XCTestCase {
    func testFinalizedTurnsAreSearchableDuringRecordingButPartialsAreNot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try SearchIndex(url: root.appendingPathComponent("index.sqlite"))
        let service = IndexService(index: index, store: MeetingStore(root: root.appendingPathComponent("Meetings")), embedder: nil)
        var meeting = Meeting(title: "Live")
        meeting.status = "recording"
        meeting.segments = [Segment(source: "system", speaker: "one", start: 0, end: 5, text: "Approved field merge for checklists.")]
        meeting.partials = ["system": "secret unfinalized hypothesis"]
        await service.liveChanged(meeting)
        for _ in 0..<50 {
            if try index.counts().chunks == 1 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(try index.search(SearchRequest("checklists")).hits.count, 1)
        XCTAssertTrue(try index.search(SearchRequest("unfinalized")).hits.isEmpty)
        XCTAssertEqual(try index.source(ref: meeting.id)?.fingerprint.hasPrefix("passages2:"), true)
        await service.finishLive()
    }
}

@MainActor final class LiveIndexHandoffTests: XCTestCase {
    func testFinalizedSpeechReachesSharedIndexWithoutRunLoopTimer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root.appendingPathComponent("Meetings"))
        let index = try SearchIndex(url: root.appendingPathComponent("index.sqlite"))
        let service = IndexService(index: index, store: store, embedder: nil)
        let model = AppModel(store: store)
        model.phase = "recording"
        var meeting = Meeting(title: "Live handoff")
        try store.save(meeting)
        model.meeting = meeting
        let hookup = SearchHookup(model: model, service: service)
        meeting.segments = [Segment(source: "system", speaker: "system:speaker-1", start: 0, end: 2, text: "The release is Friday.")]
        try store.save(meeting)
        model.meeting = meeting
        for _ in 0..<100 {
            if try index.sourceChunks(SourceID(.meeting, meeting.id)).count == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(try index.sourceChunks(SourceID(.meeting, meeting.id)).map { $0.text }, ["The release is Friday."])
        withExtendedLifetime(hookup) {}
        await service.shutdown()
    }
}
