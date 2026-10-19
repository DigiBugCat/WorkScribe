import XCTest
@testable import WorkScribeCore

final class CaptionStreamTests: XCTestCase {
    private typealias Look = CaptionStream.Look
    private func completed(_ events: [[String: Any]]) -> [String] {
        events.filter { $0["type"] as? String == "transcript.completed" }.compactMap { $0["transcript"] as? String }
    }

    func testGrowingBlockBecomesOneSegmentAfterItSettles() {
        var stream = CaptionStream(), done: [String] = []
        for (t, text) in [(0.0, "we can't"), (0.4, "we can't make October"), (0.9, "we can't make October twenty eighth")] {
            done += completed(stream.observe([Look(speaker: "Sam", text: text)], at: t))
        }
        XCTAssertTrue(done.isEmpty)
        done += completed(stream.observe([Look(speaker: "Sam", text: "we can't make October twenty eighth")], at: 2.5))
        XCTAssertEqual(done, ["we can't make October twenty eighth"])
    }

    /// The bug seen live: a finished block stays on screen and must never be finalized again.
    func testABlockStillOnScreenIsNeverRepeated() {
        var stream = CaptionStream(), done: [String] = []
        let first = Look(speaker: "Andrew", text: "Okay, let's talk about offline sync for version 2.4.")
        let second = Look(speaker: "Andrew", text: "Fine, November 4th. I'll tell Halverson on Friday.")
        done += completed(stream.observe([first], at: 0))
        done += completed(stream.observe([first], at: 2))
        for t in stride(from: 3.0, through: 60, by: 0.25) { done += completed(stream.observe([first, second], at: t)) }
        XCTAssertEqual(done, [first.text, second.text])
    }

    func testRevisedLastWordsReplaceTheOldOnes() {
        var stream = CaptionStream()
        _ = stream.observe([Look(speaker: "Priya", text: "the trial is forty")], at: 0)
        _ = stream.observe([Look(speaker: "Priya", text: "the trial is fourteen days")], at: 0.4)
        XCTAssertEqual(completed(stream.observe([Look(speaker: "Priya", text: "the trial is fourteen days")], at: 2)), ["the trial is fourteen days"])
    }

    func testEarlyRevisionOfANewBlockKeepsOneBlock() {
        var stream = CaptionStream(), done: [String] = []
        let old = Look(speaker: "Andrew", text: "Okay, that settles it.")
        done += completed(stream.observe([old], at: 0)) + completed(stream.observe([old], at: 2))
        done += completed(stream.observe([old, Look(speaker: "Andrew", text: "Fine, No")], at: 3))
        done += completed(stream.observe([old, Look(speaker: "Andrew", text: "Fine, November 4th.")], at: 3.3))
        done += completed(stream.observe([old, Look(speaker: "Andrew", text: "Fine, November 4th.")], at: 5))
        XCTAssertEqual(done, ["Okay, that settles it.", "Fine, November 4th."])
    }

    func testWordsAddedAfterAPauseAreNewNotRepeated() {
        var stream = CaptionStream()
        _ = stream.observe([Look(speaker: "Sam", text: "ship it Friday.")], at: 0)
        XCTAssertEqual(completed(stream.observe([Look(speaker: "Sam", text: "ship it Friday.")], at: 2)), ["ship it Friday."])
        _ = stream.observe([Look(speaker: "Sam", text: "ship it Friday. And tell Halvorsen.")], at: 3)
        XCTAssertEqual(completed(stream.observe([Look(speaker: "Sam", text: "ship it Friday. And tell Halvorsen.")], at: 5)), ["And tell Halvorsen."])
    }

    func testSpeakersAreNumberedInOrderAndBlocksStaySeparate() {
        var stream = CaptionStream()
        let sam = Look(speaker: "Sam", text: "I'd say November fourth")
        let maya = Look(speaker: "Maya", text: "okay November fourth it is")
        _ = stream.observe([sam], at: 0)
        let events = stream.observe([sam, maya], at: 2)
        let finals = events.filter { $0["type"] as? String == "transcript.completed" }
        XCTAssertEqual(finals.compactMap { $0["transcript"] as? String }, ["I'd say November fourth"])
        XCTAssertEqual((finals.first?["words"] as? [[String: Any]])?.first?["speaker"] as? Int, 1)
        XCTAssertEqual(completed(stream.observe([sam, maya], at: 4)), ["okay November fourth it is"])
        XCTAssertEqual(stream.names, ["Sam", "Maya"])
    }

    func testLongMonologueIsCutAtThirtySecondsWithoutLosingWords() {
        var stream = CaptionStream(), done: [String] = [], text = ""
        for i in 0..<80 { text += " word\(i)"; done += completed(stream.observe([Look(speaker: "Theo", text: text)], at: Double(i) * 0.5)) }
        done += completed(stream.flush(at: 40.1))
        XCTAssertEqual(done.joined(separator: " ").split(separator: " ").count, 80)
        XCTAssertGreaterThanOrEqual(done.count, 2)
    }

    func testFlushFinishesWhatIsOnScreenAndTimesStayOrdered() {
        var stream = CaptionStream()
        _ = stream.observe([Look(speaker: nil, text: "last words here")], at: 10)
        let final = stream.flush(at: 10.3).first
        let words = final?["words"] as? [[String: Any]] ?? []
        XCTAssertEqual(final?["transcript"] as? String, "last words here")
        XCTAssertEqual(words.first?["speaker"] as? Int, 0)
        let starts = words.compactMap { $0["start"] as? Double }
        XCTAssertEqual(starts, starts.sorted())
        XCTAssertTrue(stream.flush(at: 11).isEmpty)
    }
}
