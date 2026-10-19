import XCTest
@testable import WorkScribeCore

final class RetrievalTests: XCTestCase {
    func testPrecisionRecallAndEmptyGold() {
        let metric = RetrievalMetrics(selected: ["a", "b", "c"], gold: ["b", "c", "d", "e"], abstain: false)
        XCTAssertEqual(metric.recall!, 0.5)
        XCTAssertEqual(metric.precision!, 2.0 / 3)
        XCTAssertEqual(metric.f1!, 4.0 / 7)
        XCTAssertFalse(metric.zeroHit)
        let missing = RetrievalMetrics(selected: [], gold: ["a"], abstain: false)
        XCTAssertEqual(missing.recall, 0); XCTAssertNil(missing.precision); XCTAssertTrue(missing.zeroHit)
        let empty = RetrievalMetrics(selected: [], gold: [], abstain: true)
        XCTAssertNil(empty.recall); XCTAssertNil(empty.f1); XCTAssertFalse(empty.zeroHit); XCTAssertFalse(empty.falseMatch)
        XCTAssertTrue(RetrievalMetrics(selected: ["a"], gold: [], abstain: true).falseMatch)
        XCTAssertFalse(RetrievalMetrics(selected: ["b"], gold: ["a"], abstain: true).falseMatch)
    }
    func testChunkMembershipNeverCrossesSegments() {
        var meeting = Meeting(title: "Grouped")
        meeting.segments = (0..<3).map { i in
            var segment = Segment(source: "test", speaker: "test:1", start: Double(i * 2), end: Double(i * 2 + 2), text: "one two three four")
            segment.id = "s\(i)"; return segment
        }
        let grouped = Chunker.transcript(meeting)
        XCTAssertEqual(grouped.map(\.segmentIDs), [["s0"], ["s1"], ["s2"]])
        XCTAssertEqual(Chunker.transcript(meeting).map(\.segmentIDs), [["s0"], ["s1"], ["s2"]])
    }
    func testCacheKeysAreExactAndRoleSeparatedAndMissesListAllTexts() throws {
        var cache = RetrievalEmbeddingCache(modelID: "model@revision", dimension: 2)
        let query = RetrievalText("budget?", query: true), doc = RetrievalText("budget?", query: false)
        cache.vectors[query.key(modelID: cache.modelID)] = [1, 0]
        XCTAssertNotEqual(query.key(modelID: cache.modelID), doc.key(modelID: cache.modelID))
        XCTAssertNotEqual(query.key(modelID: cache.modelID), RetrievalText("budget? ", query: true).key(modelID: cache.modelID))
        XCTAssertNotEqual(query.key(modelID: cache.modelID), query.key(modelID: "new revision"))
        XCTAssertEqual(Set([RetrievalText("café", query: true), RetrievalText("cafe\u{301}", query: true)]).count, 2)
        let other = RetrievalText("unknown", query: true)
        XCTAssertThrowsError(try cache.require([query, doc, other])) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("2 inputs")); XCTAssertTrue(message.contains("budget?")); XCTAssertTrue(message.contains("unknown"))
        }
        XCTAssertThrowsError(try cache.require([query, doc]))
        cache.vectors[doc.key(modelID: cache.modelID)] = [1, 0]
        XCTAssertNoThrow(try cache.require([query, doc]))
    }





}
