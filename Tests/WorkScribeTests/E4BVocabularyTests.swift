import Foundation
import XCTest
import WorkScribeCore
@testable import WorkScribe

final class E4BVocabularyTests: XCTestCase {
    func testNativeTokenCountsMatchReferenceCorpus() throws {
        let path = ProcessInfo.processInfo.environment["WORKSCRIBE_TEXT_MODEL"] ?? RuntimeAssets.model(GeneratorModel.gemma4.filename).path
        guard RuntimeAssets.inspect(URL(fileURLWithPath: path)) == .present else { throw XCTSkip("E4B GGUF not installed") }
        let vocabulary = try E4BVocabulary(path: path)
        struct Reference: Decodable { var text: String; var ids: [Int] }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WorkScribeCoreTests/Golden/gemma4-tokenizer.json")
        for row in try JSONDecoder().decode([Reference].self, from: Data(contentsOf: source)) {
            XCTAssertEqual(vocabulary.count(row.text), row.ids.count, String(row.text.prefix(80)))
        }
        XCTAssertThrowsError(try E4BVocabulary(path: "/nonexistent/workscribe-model.gguf"))
    }
}
