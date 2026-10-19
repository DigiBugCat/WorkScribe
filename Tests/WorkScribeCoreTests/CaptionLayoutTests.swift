import XCTest
@testable import WorkScribeCore

/// Zoom's floating caption box while sharing, as Vision reads it: names in a smaller font, older text
/// scrolling off the top when a new block starts.
final class CaptionLayoutTests: XCTestCase {
    /// Lines top to bottom; `name` lines are drawn smaller. Coordinates are Vision's (origin bottom left).
    private func screen(_ rows: [(String, Bool)]) -> [ScreenTextLine] {
        var top = 0.95
        return rows.map { text, name in
            let height = name ? 0.07 : 0.1
            defer { top -= height + 0.04 }
            return ScreenTextLine(text: text, x: name ? 0.07 : 0.05, y: top - height, width: 0.8, height: height)
        }
    }

    func testNamedBlockAndCutOffTail() {
        let looks = CaptionLayout.looks(from: screen([
            ("support channel for the first two weeks. Third, we freeze the schema on November 1st.", false),
            ("So any migration changes need to land before then.", false),
            ("Andrew Sulistio", true),
            ("Otherwise sales cannot quote the beta.", false),
        ]))
        XCTAssertEqual(looks, [
            .init(speaker: nil, text: "support channel for the first two weeks. Third, we freeze the schema on November 1st. So any migration changes need to land before then.", continued: true),
            .init(speaker: "Andrew Sulistio", text: "Otherwise sales cannot quote the beta."),
        ])
    }

    func testOneSizeMeansNoNames() {
        let lines = [ScreenTextLine(text: "Fine, November 4th.", x: 0, y: 0.5, width: 0.5, height: 0.1),
                     ScreenTextLine(text: "I'll tell Halverson on Friday.", x: 0, y: 0.3, width: 0.5, height: 0.1)]
        XCTAssertEqual(CaptionLayout.looks(from: lines), [.init(speaker: nil, text: "Fine, November 4th. I'll tell Halverson on Friday.", continued: true)])
    }

    /// The monologue as it scrolled during a real share: one block grows, then a new block pushes its
    /// opening (and the name) off the top. Every word comes out exactly once.
    func testScrolledBlockIsNotRepeated() {
        var stream = CaptionStream()
        var completed: [String] = []
        func look(_ rows: [(String, Bool)], at t: Double) {
            for e in stream.observe(CaptionLayout.looks(from: screen(rows)), at: t) where e["type"] as? String == "transcript.completed" {
                completed.append(e["transcript"] as! String)
            }
        }
        let name = ("Andrew Sulistio", true)
        look([name, ("Let me walk through the whole rollout plan so everyone has the same picture. First, the", false),
              ("beta opens to 40 accounts on November 11th.", false)], at: 1)
        look([name, ("Let me walk through the whole rollout plan so everyone has the same picture. First, the", false),
              ("beta opens to 40 accounts on November 11th. Second, Halverson gets a dedicated", false),
              ("support channel for the first two weeks. Third, we freeze the schema on November 1st.", false)], at: 3)
        look([name, ("Let me walk through the whole rollout plan so everyone has the same picture. First, the", false),
              ("beta opens to 40 accounts on November 11th. Second, Halverson gets a dedicated", false),
              ("support channel for the first two weeks. Third, we freeze the schema on November 1st.", false),
              ("So any migration changes need to land before then.", false)], at: 5)
        look([("support channel for the first two weeks. Third, we freeze the schema on November 1st.", false),
              ("So any migration changes need to land before then.", false),
              name, ("Otherwise sales cannot quote the beta.", false)], at: 6)
        look([("support channel for the first two weeks. Third, we freeze the schema on November 1st.", false),
              ("So any migration changes need to land before then.", false),
              name, ("Otherwise sales cannot quote the beta.", false)], at: 9)
        look([], at: 20)
        completed += stream.flush(at: 21).compactMap { $0["transcript"] as? String }
        XCTAssertEqual(completed, [
            "Let me walk through the whole rollout plan so everyone has the same picture. First, the beta opens to 40 accounts on November 11th. Second, Halverson gets a dedicated support channel for the first two weeks. Third, we freeze the schema on November 1st. So any migration changes need to land before then.",
            "Otherwise sales cannot quote the beta.",
        ])
    }

    /// A tail that grows after its opening scrolled away still only adds its new words.
    func testCutOffTailKeepsGrowing() {
        var stream = CaptionStream()
        var completed: [String] = []
        func observe(_ looks: [CaptionStream.Look], _ t: Double) {
            completed += stream.observe(looks, at: t).filter { $0["type"] as? String == "transcript.completed" }.map { $0["transcript"] as! String }
        }
        observe([.init(speaker: "A", text: "one two three four five six seven")], 1)
        observe([.init(speaker: "A", text: "one two three four five six seven")], 3)
        observe([.init(speaker: nil, text: "four five six seven eight nine", continued: true)], 4)
        observe([.init(speaker: nil, text: "four five six seven eight nine", continued: true)], 6)
        XCTAssertEqual(completed, ["one two three four five six seven", "eight nine"])
    }

    /// Text with nothing to anchor to, after other blocks, is dropped rather than guessed at.
    func testUnanchoredTailStaysQuiet() {
        var stream = CaptionStream()
        _ = stream.observe([.init(speaker: "A", text: "alpha beta gamma delta")], at: 1)
        _ = stream.observe([.init(speaker: "A", text: "alpha beta gamma delta")], at: 3)
        let events = stream.observe([.init(speaker: nil, text: "completely different words here", continued: true)], at: 4)
        XCTAssertTrue(events.isEmpty)
    }
}

/// Zoom's caption panel keeps only so much text and trims the oldest paragraph from the front (seen live).
final class CaptionTrimTests: XCTestCase {
    private func run(_ frames: [(Double, [CaptionStream.Look])]) -> [String] {
        var stream = CaptionStream(), out: [String] = []
        for (t, looks) in frames {
            out += stream.observe(looks, at: t).filter { $0["type"] as? String == "transcript.completed" }.map { $0["transcript"] as! String }
        }
        return out + stream.flush(at: (frames.last?.0 ?? 0) + 1).compactMap { $0["transcript"] as? String }
    }

    func testFrontTrimmedParagraphIsNotRepeated() {
        let a = "I'm going to ignore those. Let's lock the beta plan. The beta opens to forty accounts on November eleventh."
        let b = "The schema freezes on November first, so migrations land before then."
        let out = run([
            (1, [.init(speaker: "A", text: a)]), (3, [.init(speaker: "A", text: a)]),
            (4, [.init(speaker: "A", text: a), .init(speaker: "A", text: b)]), (6, [.init(speaker: "A", text: a), .init(speaker: "A", text: b)]),
            (7, [.init(speaker: "A", text: "Let's lock the beta plan. The beta opens to forty accounts on November eleventh."), .init(speaker: "A", text: b)]),
            (9, [.init(speaker: "A", text: "The beta opens to forty accounts on November eleventh."), .init(speaker: "A", text: b + " QA needs a week.")]),
            (12, [.init(speaker: "A", text: "The beta opens to forty accounts on November eleventh."), .init(speaker: "A", text: b + " QA needs a week.")]),
        ])
        XCTAssertEqual(out, [a, b, "QA needs a week."])
    }

    /// A later block that happens to open like a trimmed older one stays its own block.
    func testRepeatedOpeningDoesNotCaptureATrimmedBlock() {
        let first = "Hello everyone. Let's lock the beta plan. The beta opens to forty accounts on November eleventh."
        let second = "Let's lock the beta plan. The beta opens to forty accounts on November eleven, and Halvorsen gets support."
        let out = run([
            (1, [.init(speaker: "A", text: first)]), (3, [.init(speaker: "A", text: first)]),
            (4, [.init(speaker: "A", text: first), .init(speaker: "A", text: second)]),
            (6, [.init(speaker: "A", text: first), .init(speaker: "A", text: second)]),
            (7, [.init(speaker: "A", text: "Let's lock the beta plan. The beta opens to forty accounts on November eleventh."), .init(speaker: "A", text: second)]),
            (10, [.init(speaker: "A", text: "Let's lock the beta plan. The beta opens to forty accounts on November eleventh."), .init(speaker: "A", text: second)]),
        ])
        XCTAssertEqual(out, [first, second])
    }
}

/// Restarting mid-call: the captions still on screen were already transcribed before the restart.
final class CaptionResumeTests: XCTestCase {
    func testResumeContinuesWithoutRewritingWhatIsOnScreen() {
        var stream = CaptionStream()
        stream.prime(with: "Let's lock the beta plan. The beta opens to forty accounts on November 11th,", at: 100)
        var out: [String] = []
        func observe(_ text: String, _ t: Double) {
            out += stream.observe([.init(speaker: "A", text: text)], at: t).filter { $0["type"] as? String == "transcript.completed" }.map { $0["transcript"] as! String }
        }
        observe("Let's lock the beta plan. The beta opens to forty accounts on November 11th, and Halvorsen", 101)
        observe("Let's lock the beta plan. The beta opens to forty accounts on November 11th, and Halvorsen gets support.", 102)
        observe("Let's lock the beta plan. The beta opens to forty accounts on November 11th, and Halvorsen gets support.", 104)
        XCTAssertEqual(out, ["and Halvorsen gets support."])
    }

    func testNewSpeechAfterTheResumeWindowIsNeverSkipped() {
        var stream = CaptionStream()
        stream.prime(with: "The beta opens to forty accounts on November eleventh.", at: 0)
        _ = stream.observe([], at: 1)
        let events = stream.observe([.init(speaker: "A", text: "The beta opens to forty accounts on November eleventh.")], at: 30)
        XCTAssertEqual(events.first?["transcript"] as? String, "The beta opens to forty accounts on November eleventh.")
    }
}
