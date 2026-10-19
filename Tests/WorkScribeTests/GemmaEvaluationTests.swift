import Foundation
import XCTest
@testable import WorkScribe
import WorkScribeCore

final class GemmaEvaluationTests: XCTestCase {
    func testThinkingOffSingleTurnTemplate() {
        // Exact rendering of the pinned jinja template, enable_thinking=false, no system/tools.
        XCTAssertEqual(GemmaEvaluation.template.head + "hello" + GemmaEvaluation.template.tail,
                       "<bos><|turn>user\nhello<turn|>\n<|turn>model\n")
        XCTAssertFalse(GemmaEvaluation.template.head.contains("<|think|>"))
        let llama = LlamaTextEngine.template(.gemma4)
        XCTAssertEqual("<bos>" + llama.head, GemmaEvaluation.template.head)
        XCTAssertEqual(llama.tail, GemmaEvaluation.template.tail)
    }

    func testResidentGemmaPrefixRestoresExactly() async throws {
        guard ProcessInfo.processInfo.environment["WORKSCRIBE_TEST_E4B"] == "1" else { throw XCTSkip("Set WORKSCRIBE_TEST_E4B=1 for local GPU integration test") }
        let model = try GemmaEvaluation.model(runtime: "llama")
        await model.release()
        let head = LinePrompt.rules
        let request = TextRequest(head + "<note>ship date</note>\n<evidence id=\"E1\">The ship date is November fourth.</evidence>", cacheablePrefix: head, maxTokens: 200, stop: NotePrompt.endMarker)
        do {
            let first = try await model.generate(request)
            let second = try await model.generate(request)
            let third = try await model.generate(request)
            XCTAssertTrue(first.stats.prefixBuilt)
            XCTAssertGreaterThan(second.stats.reusedTokens, 32)
            XCTAssertEqual(first.text, second.text)
            XCTAssertEqual(second.text, third.text)
            XCTAssertFalse(second.text.isEmpty)
            XCTAssertFalse(second.text.contains("<|channel>thought"))
            XCTAssertEqual(second.stats.loadMs, 0)
            await model.release()
        } catch { await model.release(); throw error }
    }
}
