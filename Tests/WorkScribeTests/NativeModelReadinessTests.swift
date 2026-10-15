import Foundation
import XCTest
import CTextGeneration
import CNemo

final class NativeModelReadinessTests: XCTestCase {
    func testTextBridgeRejectsMissingModelBeforeLoadingBackend() {
        var output = [CChar](repeating: 0, count: 32)
        var error = [CChar](repeating: 0, count: 256)
        let result = ws_generate_title("/nonexistent/workscribe-model.gguf", "test", &output, output.count, &error, error.count)
        XCTAssertNotEqual(result, 0)
        XCTAssertTrue(String(cString: error).contains("missing or evicted"))
    }
    func testSpeechBridgeRejectsEmptyModel() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gguf")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var recognizer: OpaquePointer?
        XCTAssertEqual(ws_engine_create(url.path, url.path, &recognizer), NEMO_SPEECH_ASR_ERROR_INVALID_ARGUMENT)
        XCTAssertNil(recognizer)
    }
}
