import XCTest
import WorkScribeCore
@testable import WorkScribe

/// The day's screen history through the real EmbeddingGemma 2 model on this Mac: every stretch of text gets a
/// vector, and a question finds the right window by meaning, with none of its words. Skipped when the model is
/// not installed.
final class ScreenDayEmbeddingTests: XCTestCase {
    func testADaysTextIsEmbeddedAndFoundByMeaning() async throws {
        // Loading the real model takes about ten seconds (a minute and a half the first time on a Mac), and the
        // rest of the suite needs no model at all: `WORKSCRIBE_REAL_MODELS=1 swift test --filter ScreenDayEmbeddingTests`.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WORKSCRIBE_REAL_MODELS"] == "1", "set WORKSCRIBE_REAL_MODELS=1 to run against the real EmbeddingGemma 2 model")
        guard let embedder = CoreMLEmbedder.bundled() else { throw XCTSkip("EmbeddingGemma 2 is not installed in the runtime home") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("screen-embed-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScreenDayStore(root: root.appendingPathComponent(".screen"))
        var day = ScreenDay(day: "2026-11-11", start: Date(timeIntervalSince1970: 1_794_384_000))
        day.moments = [
            ScreenMoment(id: "pricing", start: 34_200, end: 34_260, text: "Team plan: twelve dollars per seat each month, billed annually. Enterprise: contact sales.",
                         app: "Safari", bundleID: "com.apple.Safari", window: "Plans — Acme"),
            ScreenMoment(id: "code", start: 36_000, end: 36_100, text: "func start() async throws { guard !startClaimed else { return } startClaimed = true }",
                         app: "Xcode", bundleID: "com.apple.dt.Xcode", window: "AppModel.swift"),
            ScreenMoment(id: "recipe", start: 43_200, end: 43_300, text: "Simmer the lentils with cumin and garlic for twenty minutes, then stir in spinach and lemon.",
                         app: "Notes", bundleID: "com.apple.Notes", window: "Dinner"),
        ]
        try store.save(day)
        let index = try SearchIndex(url: root.appendingPathComponent("index.sqlite"))
        let report = try await ScreenDayIndexer(index: index, embedder: embedder).sync(store: store)
        XCTAssertEqual(report.indexed, 1)

        let chunks = try index.sourceChunks(SourceID(.screen, ScreenDaySource.ref(day.day)))
        XCTAssertEqual(chunks.count, 3)
        XCTAssertTrue(chunks.allSatisfy { $0.vector?.isEmpty == false }, "every stretch of text has a vector")
        XCTAssertEqual(index.vectorModel, embedder.modelID)

        // Asked in other words: nothing here shares a content word with the window it should find.
        for (question, expected) in [("how much would it cost for every user", "Plans"), ("what are we cooking tonight", "Dinner")] {
            let vector = try await embedder.text(question, role: .query)
            index.invalidate()
            let hit = try XCTUnwrap(try index.search(SearchRequest(question, limit: 3), queryVector: vector, queryModelID: embedder.modelID).hits.first, question)
            XCTAssertEqual(hit.sourceKind, .screen)
            XCTAssertTrue(hit.window?.contains(expected) ?? false, "\(question) found \(hit.window ?? "nothing")")
        }
        await embedder.release()
    }
}
