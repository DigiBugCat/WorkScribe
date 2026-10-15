import XCTest
@testable import WorkScribeCore

final class ScreenSceneTests: XCTestCase {
    private func v(_ a: Float, _ b: Float) -> [Float] { [a, b] + Array(repeating: 0, count: 766) }
    private func observation(_ time: Double, _ vector: [Float], _ stability: Double = 0, _ app: String = "doc") -> ScreenSceneDetector.Observation {
        .init(time: time, vector: vector, frameID: "f\(time)", stability: stability, app: app, bundleID: app)
    }
    func testScrollingTransientAndHysteresisDoNotSplitScene() {
        var detector = ScreenSceneDetector()
        detector.add(observation(0, v(1,0)), modelID: "test")
        detector.add(observation(5, v(0.98,0.1), 0.7), modelID: "test")
        detector.add(observation(10, v(0,1)), modelID: "test") // transient menu
        detector.add(observation(12.5, v(1,0), 0.99), modelID: "test")
        detector.add(observation(15, v(0.90,0.435)), modelID: "test") // deadband
        XCTAssertEqual(detector.all.count, 1)
        XCTAssertFalse(detector.needsConfirmation)
        XCTAssertEqual(detector.open?.representativeTime, 12.5)
        XCTAssertEqual(detector.open?.text, "")
    }
    func testStableBoundaryBackdatesAndDoesNotMergeApps() {
        var detector = ScreenSceneDetector()
        detector.add(observation(0, v(1,0)), modelID: "test")
        detector.add(observation(10, v(0,1)), modelID: "test")
        detector.add(observation(12.5, v(0,1), 1), modelID: "test")
        XCTAssertEqual(detector.all.count, 1)
        detector.add(observation(15, v(0,1)), modelID: "test")
        XCTAssertEqual(detector.all.count, 2)
        XCTAssertEqual(detector.closed[0].end, 10)
        XCTAssertEqual(detector.open?.start, 10)
        detector.add(observation(20, v(0,1), 0, "slides"), modelID: "test")
        detector.add(observation(25, v(0,1), 1, "slides"), modelID: "test")
        XCTAssertEqual(detector.all.count, 3)
        XCTAssertEqual(detector.open?.bundleID, "slides")
        XCTAssertEqual(detector.representatives.count, 1)
    }
    func testMalformedVectorsAndLateFramesCannotCorruptCentroid() {
        var detector = ScreenSceneDetector()
        XCTAssertFalse(detector.add(observation(0, [1]), modelID: "test"))
        XCTAssertFalse(detector.add(observation(0, v(.nan,0)), modelID: "test"))
        XCTAssertTrue(detector.add(observation(1, v(1,0)), modelID: "test"))
        XCTAssertFalse(detector.add(observation(0, v(0,1)), modelID: "test"))
        let id = detector.open!.id
        detector.freezeRepresentative(id)
        detector.add(observation(5, v(1,0), 1), modelID: "test")
        XCTAssertEqual(detector.open?.representativeTime, 1)
        detector.close(at: 6)
        detector.add(observation(10, v(1,0)), modelID: "test")
        XCTAssertEqual(detector.all.count, 2) // privacy/pause gap is never bridged
    }
    func testPressureReducesSamplingThenDefersInference() {
        let slow = ScreenWorkBudget(pressure: .screenPaused)
        XCTAssertEqual(slow.sampleInterval, 7.5)
        XCTAssertTrue(slow.embeddings); XCTAssertFalse(slow.ocr)
        XCTAssertFalse(ScreenWorkBudget(pressure: .aiPaused).embeddings)
        XCTAssertFalse(ScreenWorkBudget(pressure: .normal, thermalLevel: 2).embeddings)
        XCTAssertTrue(ScreenWorkBudget(pressure: .normal).ocr)
    }
    func testSceneVectorsUseImageChunksWithoutOCR() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try SearchIndex(url: root.appendingPathComponent("index.sqlite"))
        var meeting = Meeting(title: "Review"); meeting.status = "complete"
        var detector = ScreenSceneDetector()
        detector.add(observation(0, v(1,0)), modelID: "test")
        let scenes = detector.finish(at: 10)
        try await MeetingIndexer(index: index, embedder: nil).index(meeting, screen: scenes, folder: root)
        let hits = try index.search(SearchRequest("dashboard", kinds: [.screen]), queryVector: v(1,0), queryModelID: "test")
        XCTAssertEqual(hits.hits.first?.kind, .screen)
        XCTAssertNotNil(hits.hits.first?.thumbnail)
        XCTAssertEqual(try index.vectorStats().count, 1)
        try index.purge(refs: [meeting.id])
        XCTAssertEqual(try index.vectorStats().count, 0)
        XCTAssertTrue(try index.search(SearchRequest("dashboard"), queryVector: v(1,0), queryModelID: "test").hits.isEmpty)
    }
    func testOldSceneSpaceCannotEvictCurrentLibraryVectors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try SearchIndex(url: root.appendingPathComponent("index.sqlite"))
        try index.adopt(modelID: "current")
        try index.replace(kind: .file, ref: "kept", title: "kept", fingerprint: "1", modelID: "current",
                          chunks: [Chunk(kind: .image, modality: .image, vector: v(1,0))])
        var detector = ScreenSceneDetector()
        detector.add(observation(0, v(0,1)), modelID: "old")
        let meeting = Meeting(title: "Old scene")
        try await MeetingIndexer(index: index, embedder: nil).index(meeting, screen: detector.finish(at: 20))
        XCTAssertEqual(index.vectorModel, "current")
        XCTAssertEqual(try index.vectorStats().count, 1)
        XCTAssertEqual(try index.search(SearchRequest("picture"), queryVector: v(1,0), queryModelID: "current").hits.first?.ref, "kept")
    }

    func testEarlySwitchCanSettleInsteadOfRemainingCandidateForever() {
        var detector = ScreenSceneDetector()
        detector.add(observation(0, v(1,0)), modelID: "test")
        detector.add(observation(2.5, v(0,1)), modelID: "test")
        detector.add(observation(5, v(0,1)), modelID: "test")
        detector.add(observation(7.5, v(0,1)), modelID: "test")
        XCTAssertEqual(detector.all.count, 2)
        XCTAssertEqual(detector.open?.start, 2.5)
        XCTAssertFalse(detector.needsConfirmation)
    }

}
