import CTextGeneration
import Foundation
import Metal
import XCTest
@testable import WorkScribe
import WorkScribeCore

/// A backend that records what the resident wrapper asks of it.
private final class FakeEngine: TextEngine, @unchecked Sendable {
    let lock = NSLock()
    private var loaded = false
    private(set) var loads = 0, unloads = 0, drops = 0, calls = 0
    /// While set, `generate` spins until the call is cancelled or this is cleared.
    var hold = false
    var isLoaded: Bool { lock.withLock { loaded } }
    func load() throws { lock.withLock { loaded = true; loads += 1 } }
    func generate(_ request: TextRequest, control: GenerationControl) throws -> TextGeneration {
        lock.withLock { calls += 1 }
        while lock.withLock({ hold }) {
            if control.isCancelled { throw CancellationError() }
            usleep(1_000)
        }
        for word in request.instruction.split(separator: " ") {
            if control.isCancelled { throw CancellationError() }
            if control.onPiece?(String(word) + " ") == false { throw CancellationError() }
        }
        return TextGeneration(text: request.instruction, stats: TextStats(promptTokens: 1))
    }
    func dropCaches() { lock.withLock { drops += 1 } }
    func unload() { lock.withLock { if loaded { unloads += 1 }; loaded = false } }
}

final class TextModelTests: XCTestCase {
    private func resident(_ engine: FakeEngine, idle: Duration = .seconds(300)) -> ResidentTextModel {
        ResidentTextModel(displayName: "Fake · llama.cpp", backend: .llama, engine: engine, idleTimeout: idle, available: { true })
    }

    func testIdleTimeoutIsFiveMinutes() {
        XCTAssertEqual(ResidentTextModel.idleTimeout, .seconds(300))
    }

    func testLoadsOnceAndIsReusedByEveryCall() async throws {
        let engine = FakeEngine(), model = resident(engine)
        let first = try await model.generate(TextRequest("one", maxTokens: 4))
        let second = try await model.generate(TextRequest("two", maxTokens: 4))
        _ = try await model.generate(TextRequest("three", maxTokens: 4))
        XCTAssertEqual(engine.loads, 1)
        XCTAssertEqual(engine.calls, 3)
        let loads = await model.loads
        XCTAssertEqual(loads, 1)
        XCTAssertGreaterThanOrEqual(first.stats.loadMs, 0)
        XCTAssertEqual(second.stats.loadMs, 0, "only the loading call reports a load")
        let loaded = await model.isLoaded
        XCTAssertTrue(loaded)
    }

    func testReleasedAfterIdleAndReloadedOnNextUse() async throws {
        let engine = FakeEngine(), model = resident(engine, idle: .milliseconds(150))
        _ = try await model.generate(TextRequest("one", maxTokens: 4))
        // Calls closer together than the timeout keep it loaded.
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(60))
            _ = try await model.generate(TextRequest("again", maxTokens: 4))
        }
        XCTAssertEqual(engine.unloads, 0)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(engine.unloads, 1)
        let loaded = await model.isLoaded
        XCTAssertFalse(loaded)
        _ = try await model.generate(TextRequest("back", maxTokens: 4))
        XCTAssertEqual(engine.loads, 2)
    }

    func testMemoryPressureReleasesAnIdleModel() async throws {
        let engine = FakeEngine(), model = resident(engine)
        _ = try await model.generate(TextRequest("one", maxTokens: 4))
        await model.memoryPressure()
        XCTAssertEqual(engine.drops, 1)
        XCTAssertEqual(engine.unloads, 1)
        let loaded = await model.isLoaded
        XCTAssertFalse(loaded)
    }

    func testMemoryPressureDuringACallReleasesWhenItFinishes() async throws {
        let engine = FakeEngine(), model = resident(engine)
        _ = try await model.generate(TextRequest("warm", maxTokens: 4))
        engine.lock.withLock { engine.hold = true }
        let call = Task { try await model.generate(TextRequest("busy", maxTokens: 4)) }
        while engine.calls < 2 { try await Task.sleep(for: .milliseconds(5)) }
        let pressure = Task { await model.memoryPressure() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(engine.unloads, 0, "the call in flight keeps its model")
        engine.lock.withLock { engine.hold = false }
        _ = try await call.value
        await pressure.value
        for _ in 0..<100 where engine.unloads == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(engine.unloads, 1)
    }

    /// A live pass yields to speech recognition by being cancelled: the engine sees it mid-call.
    func testCancellationStopsTheEngineMidCall() async throws {
        let engine = FakeEngine(), model = resident(engine)
        engine.lock.withLock { engine.hold = true }
        let call = Task { try await model.generate(TextRequest("long", maxTokens: 4)) }
        while engine.calls < 1 { try await Task.sleep(for: .milliseconds(5)) }
        call.cancel()
        do { _ = try await call.value; XCTFail("expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        engine.lock.withLock { engine.hold = false }
        let after = try await model.generate(TextRequest("next", maxTokens: 4))
        XCTAssertEqual(after.text, "next")
    }

    func testStreamDeliversPieces() async throws {
        let engine = FakeEngine(), model = resident(engine)
        var text = ""
        for try await piece in model.stream(TextRequest("a b c", maxTokens: 4)) { text += piece }
        XCTAssertEqual(text, "a b c ")
    }

    func testRequestKeepsOnlyARealPrefix() {
        XCTAssertEqual(TextRequest("rules then data", cacheablePrefix: "rules ", maxTokens: 1).cacheablePrefix, "rules ")
        XCTAssertNil(TextRequest("data", cacheablePrefix: "rules ", maxTokens: 1).cacheablePrefix)
    }

    func testJobsUseTheExpectedBackends() {
        for job in [TextJob.line, .line, .brief, .title, .ask] {
            let model = TextModels.model(for: job)
            XCTAssertEqual(model.backend, .llama)
            XCTAssertEqual(model.displayName, "Gemma 4 E4B · llama.cpp")
            XCTAssertTrue((model as? ResidentTextModel) === TextModels.generator(.gemma4))
        }
        XCTAssertEqual(GeneratorModel.bundled, .gemma4)
        XCTAssertEqual(GeneratorModel.bundled.filename, "gemma-4-E4B-it-Q4_0.gguf")
    }

    // MARK: Real models (skipped when the runtime doctor has not installed them)

    private static let evidence = [
        "Okay, so offline sync for two point four. The conflict rule is last write wins for everything except checklists, where we merge at the field level.",
        "The ship date is November fourth, but the SQL live migration requires a full week, so October twenty eighth won't work.",
    ]
    private func linePrompt(_ note: String, _ evidence: String) -> String {
        LinePrompt.rules + "<note>\(note)</note>\n<evidence id=\"E1\">\(evidence)</evidence>"
    }

    /// Restoring the saved instruction state is exact: the cached path writes the same bytes as
    /// prefilling the whole prompt, on the call that builds the prefix and on the calls that reuse it.
    func testLlamaPrefixCacheIsByteIdenticalToTheUncachedPath() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device; run the E4B prefix check outside the sandbox") }
        let path = ProcessInfo.processInfo.environment["WORKSCRIBE_TEXT_MODEL"] ?? RuntimeAssets.model(GeneratorModel.gemma4.filename).path
        guard RuntimeAssets.inspect(URL(fileURLWithPath: path)) == .present else { throw XCTSkip("E4B GGUF not installed") }
        let engine = LlamaTextEngine(model: .gemma4, path: path)
        try engine.load()
        defer { engine.unload() }
        let template = LlamaTextEngine.template(.gemma4)
        let vocabulary = try E4BVocabulary(path: path)
        for (index, (note, text)) in [("lww?", Self.evidence[0]), ("ship date", Self.evidence[1]), ("lww?", Self.evidence[0])].enumerated() {
            let instruction = linePrompt(note, text)
            // The reference: the one-shot path, its own model and context, no state restored.
            var output = [CChar](repeating: 0, count: 64 * 1024), error = [CChar](repeating: 0, count: 512)
            XCTAssertEqual(ws_generate_text(path, template.head + instruction + template.tail, 8192, 120, NotePrompt.endMarker,
                                            &output, output.count, &error, error.count), 0, String(cString: error))
            let reference = String(cString: output)
            let cached = try engine.generate(TextRequest(instruction, cacheablePrefix: LinePrompt.rules, maxTokens: 120, stop: NotePrompt.endMarker),
                                             control: GenerationControl())
            let plain = try engine.generate(TextRequest(instruction, maxTokens: 120, stop: NotePrompt.endMarker), control: GenerationControl())
            XCTAssertFalse(reference.isEmpty)
            XCTAssertEqual(cached.text, reference, "cached call \(index)")
            XCTAssertEqual(plain.text, reference, "resident uncached call \(index)")
            XCTAssertEqual(cached.stats.prefixBuilt, index == 0)
            XCTAssertEqual(cached.stats.reusedTokens > 0, index > 0)
            XCTAssertEqual(plain.stats.reusedTokens, 0)
            XCTAssertEqual(plain.stats.promptTokens, vocabulary.count("<bos>" + template.head + instruction + template.tail))
        }
    }


}
