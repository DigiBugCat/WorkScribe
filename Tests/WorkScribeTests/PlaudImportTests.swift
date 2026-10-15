#if WORKSCRIBE_PLAUD
import XCTest
import WorkScribeCore
import WorkScribePlaud
@testable import WorkScribe

@MainActor
final class PlaudImportTests: XCTestCase {
    func testAlreadyImportedRecordingsAreNotQueuedAgain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        var existing = Meeting(title: "Note Pro · earlier", titleOrigin: "automatic")
        existing.status = "complete"; existing.recordingTrigger = "plaud:8810001:1790000000"
        try store.save(existing)
        let model = AppModel(store: store, titleGenerator: ControlledTitleGenerator())
        model.importPlaud([PlaudSavedRecording(id: "8810001:1790000000", audioURL: root.appendingPathComponent("a.wav"), recordedAt: nil)])
        XCTAssertTrue(model.importQueue.isEmpty)
        XCTAssertEqual(model.importStatus, "These recordings are already in Recent.")
    }
    func testLevelsRiseImmediatelyAndFallGently() {
        let levels = LevelMonitor()
        levels.update(microphone: 0.9, system: 0.5)
        XCTAssertEqual(levels.microphone, 0.9, accuracy: 0.0001)
        levels.update(microphone: 0, system: 0)
        XCTAssertEqual(levels.microphone, 0.72, accuracy: 0.0001)
        XCTAssertEqual(levels.system ?? 0, 0.4, accuracy: 0.0001)
        levels.update(microphone: 0, system: nil)
        XCTAssertNil(levels.system)
    }
}

#endif
