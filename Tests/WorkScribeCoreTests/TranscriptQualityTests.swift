import XCTest
@testable import WorkScribeCore

final class TranscriptQualityTests: XCTestCase {
    func testEmptyUpdatesCannotEraseVisibleWordsOrTheirAnchor() {
        var meeting = Meeting(title: "Handoff")
        meeting.setPartial("the last words", source: "system", speaker: nil)
        let id = meeting.partialIDs?["system"]
        meeting.setPartial("", source: "system", speaker: nil)
        meeting.finishPartial([], source: "system")
        XCTAssertEqual(meeting.partials["system"], "the last words")
        XCTAssertEqual(meeting.partialIDs?["system"], id)
    }
    func testTimestampLessAndMetadataMissingWordsArePreserved() {
        let event: [String: Any] = ["transcript": "Maybe that could trip them out. Oh, that was the last bit of drama.", "audio_processed": 10.0,
            "words": [["word": "Maybe", "start": 1.0, "end": 2.0, "speaker": 2],
                      ["word": "that"], ["word": "could", "start": 3.0, "end": 3.4],
                      ["word": "trip", "start": 4.0, "end": 4.2], ["word": "them", "start": 4.2, "end": 4.4],
                      ["word": "the", "start": 7.0, "end": 7.2], ["word": "last", "start": 7.2, "end": 7.4]]]
        let result = TranscriptParser.segments(event: event, source: "system", offset: 100, fallbackStart: 100)
        XCTAssertEqual(result.map(\.text).joined(separator: " "), event["transcript"] as? String)
        XCTAssertTrue(result.allSatisfy { $0.start.isFinite && $0.end >= $0.start && $0.start >= 100 })
        XCTAssertEqual(result.first?.speaker, "system:speaker-2")
    }
    func testOnlyUntimedWordsAndTextFallbackStillSurvive() {
        for event: [String: Any] in [["words": [["word": "one"], ["word": "two"]]], ["transcript": "one two", "audio_processed": 4.0]] {
            XCTAssertEqual(TranscriptParser.segments(event: event, source: "mic", offset: 0, fallbackStart: 0).map(\.text).joined(separator: " "), "one two")
        }
    }
    func testUntimedRunUsesNeighboringTimeAndRepeatedWordsKeepAlignment() {
        let words = TranscriptParser.timedWords(event: ["transcript": "the missing words the end", "audio_processed": 5.0,
            "words": [["word": "the", "start": 0.0, "end": 1.0], ["word": "the", "start": 3.0, "end": 4.0],
                      ["word": "end", "start": 4.0, "end": 5.0]]], offset: 0, fallbackStart: 0)
        XCTAssertEqual(words.map(\.text), ["the", "missing", "words", "the", "end"])
        XCTAssertEqual(words[1].start, 1); XCTAssertEqual(words[1].end, 2)
        XCTAssertEqual(words[2].start, 2); XCTAssertEqual(words[2].end, 3)
        XCTAssertEqual(words[3].start, 3)
    }
    func testLoadSheddingKeepsNewestPartialForEmptyFinal() {
        var meeting = Meeting(title: "Pressure"), reducer = LiveTranscript()
        let now = Date()
        reducer.consume(["type": "transcript.partial", "transcript": "first"], source: "system", offset: 0, pressure: .transcriptDelayed, meeting: &meeting, now: now)
        let anchor = meeting.partialIDs?["system"]
        reducer.consume(["type": "transcript.partial", "transcript": "first and the rest"], source: "system", offset: 0, pressure: .transcriptDelayed, meeting: &meeting, now: now.addingTimeInterval(1))
        XCTAssertEqual(meeting.partials["system"], "first")
        reducer.consume(["type": "transcript.completed", "transcript": ""], source: "system", offset: 0, pressure: .transcriptDelayed, meeting: &meeting)
        XCTAssertEqual(meeting.segments.map(\.text).joined(separator: " "), "first and the rest")
        XCTAssertEqual(meeting.segments.first?.id, anchor)
        XCTAssertTrue(meeting.partials.isEmpty)
        XCTAssertEqual(reducer.hiddenPartials, 1)
    }
    func testFinalSupersedesHypothesisWithoutConcatenatingWrongWords() {
        var meeting = Meeting(title: "Correction"), reducer = LiveTranscript()
        reducer.consume(["type": "transcript.partial", "transcript": "a billion"], source: "system", offset: 0, pressure: .normal, meeting: &meeting)
        reducer.consume(["type": "transcript.completed", "transcript": "a million", "audio_processed": 2.0], source: "system", offset: 0, pressure: .transcriptDelayed, meeting: &meeting)
        XCTAssertEqual(meeting.segments.first?.text, "a million")
        reducer.consume(["type": "transcript.completed", "transcript": "", "words": []], source: "system", offset: 0, pressure: .normal, meeting: &meeting)
        XCTAssertEqual(meeting.segments.count, 1)
    }

    func testMarkdownViewDoesNotCarrySyntaxIntoPrompt() {
        XCTAssertEqual(NotePlainText.clean("> - [x] **needs** [[Compass|compass]] + [food](food.md) `now` ^note-id"), "needs compass + food now")
    }
    func testFinalTopicPlanCoversEveryEligibleChunk() throws {
        var meeting = Meeting(title: "Long discussion")
        meeting.segments = (0..<80).map { Segment(source: "system", speaker: "system:speaker-1", start: Double($0 * 30), end: Double($0 * 30 + 10), text: "Topic number \($0) includes a concrete challenge rule and outcome.") }
        let uncovered = UncoveredDiscussion.excerpts(meeting)
        XCTAssertEqual(uncovered.count, Chunker.transcript(meeting).count)
        XCTAssertTrue(uncovered.contains { $0.chunk.text.contains("number 79") })
    }
    func testFinalTopicSelectionCannotEraseAnEarlierChapter() throws {
        var meeting = Meeting(title: "Stream")
        meeting.segments = (0..<8).map { Segment(source: "system", speaker: "system:speaker-1", start: Double($0 * 300), end: Double($0 * 300 + 10), text: "A substantial topic with enough words for a complete discussion.") }
        let uncovered = UncoveredDiscussion.excerpts(meeting)
        let topics = [Bullet(topic: "Hokkaido reservations", text: "Reservations may be needed.", refs: ["U1"]),
                      Bullet(topic: "Japan food hunt", text: "The challenge has a one-hour limit.", refs: ["U2"])] +
            (3...8).map { Bullet(topic: "Cruise topic \($0)", text: "A different later activity.", refs: ["U\($0)"]) }
        let result = NoteOutput.balancedTopics(topics, excerpts: uncovered, limit: 5)
        XCTAssertTrue(result.contains { $0.topic == "Hokkaido reservations" })
        XCTAssertTrue(result.contains { $0.topic == "Japan food hunt" })
        XCTAssertLessThanOrEqual(result.count, 5)
    }
}
