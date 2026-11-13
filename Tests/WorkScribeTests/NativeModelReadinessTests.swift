import Foundation
import XCTest
import CNemo

final class NativeModelReadinessTests: XCTestCase {
    func testSpeechBridgeRejectsEmptyModel() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gguf")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var recognizer: OpaquePointer?
        XCTAssertEqual(ws_engine_create(url.path, url.path, &recognizer), NEMO_SPEECH_ASR_ERROR_INVALID_ARGUMENT)
        XCTAssertNil(recognizer)
    }
}
