import XCTest
@testable import WorkScribeCore

/// The pieces of the record → note path that are pure: brief, grounding, commitments, capture health.
final class HappyPathTests: XCTestCase {
    // MARK: Brief

    /// The brief an auto-finalized note actually got: three note lines glued together, model
    /// markup and all, then escaped into one italic line.
    func testBrokenBriefRegression() {
        let glued = "**Cutscenes remaining:** 1 billion left. **Resources needed:** Compass and food. - car broken earlier?"
        let facts = ["Probably a couple cutscenes", "I need my compass", "unless I get more food"]
        XCTAssertNil(BriefPolicy.clean(glued, evidence: facts))
        XCTAssertNil(BriefPolicy.clean("* The team agreed to ship on Friday.", evidence: ["ship on Friday"]))
        XCTAssertNil(BriefPolicy.clean("Brief:\n- Ship Friday\n- QA a week", evidence: ["ship Friday", "QA a week"]))
        XCTAssertNil(BriefPolicy.clean("The team moved the release to Friday. (E1, E2)", evidence: ["release moves to Friday"]))
        // A number the notes never state is not a summary, it is an invention.
        XCTAssertNil(BriefPolicy.clean("The stream has 1 billion cutscenes left and needs a compass.", evidence: ["a more billion cutscenes left", "I need my compass"]))
        let facts2 = ["The team will merge at the field level for checklists while keeping last write wins for everything else.",
                      "The ship date is November fourth because the SQLite migration needs a full week of QA.",
                      "Action: Prototype checklist merge by Monday"]
        XCTAssertEqual(BriefPolicy.clean("The team agreed to merge checklists at the field level, prototype by Monday, and ship on November fourth.</output>", evidence: facts2),
                       "The team agreed to merge checklists at the field level, prototype by Monday, and ship on November fourth.")
        XCTAssertEqual(BriefPolicy.clean("Summary: The ship date is November fourth because QA needs a full week.", evidence: facts2),
                       "The ship date is November fourth because QA needs a full week.")
        // Too long as two sentences: the first one is the brief.
        let long = "The team will merge at the field level for checklists while keeping last write wins for everything else, with a prototype by Monday. The ship date is November fourth because the SQLite migration needs a full week of QA and October twenty eighth will not work."
        XCTAssertEqual(BriefPolicy.clean(long, evidence: facts2 + ["October twenty eighth will not work"]),
                       "The team will merge at the field level for checklists while keeping last write wins for everything else, with a prototype by Monday.")
    }

    func testBriefOnlyFromFinishedLines() {
        var meeting = Meeting(title: "Sync")
        var grounded = Note(text: "- photo cap", createdAt: 120)
        grounded.line.text = "**photo cap:** Cap the queue at 200 photos or 1.5 GB per device."; grounded.line.evidence = ["s#0"]
        var bare = Note(text: "- pricing?", createdAt: 130)
        bare.line.text = "**pricing:** Pricing is 2.5."; bare.line.evidence = []
        meeting.notes = [grounded, bare]
        XCTAssertEqual(BriefPolicy.facts(meeting), ["Cap the queue at 200 photos or 1.5 GB per device."])
        XCTAssertTrue(BriefPolicy.prompt(meeting).contains("photo cap"))
        XCTAssertFalse(BriefPolicy.prompt(meeting).contains("Pricing is 2.5"))
        XCTAssertTrue(BriefPolicy.facts(Meeting(title: "Empty")).isEmpty)
    }

    /// The live test's actual model output: the template label copied literally, the topic on the
    /// bullet line and the sentence wrapped onto the next. It used to be thrown away whole.


    // MARK: Grounding

    func testSpokenAndWrittenNumbersAreTheSame() {
        XCTAssertEqual(Grounding.numbers(in: "four thirty. three and a half hours"), [34, 3.5])
        XCTAssertTrue(Grounding.supported("We were done by four thirty after starting at one.", evidence: ["we started at one and were done by four thirty", "three and a half hours tops"]))
        XCTAssertFalse(NoteOutput.usable(Bullet(topic: "Trial", text: Array(repeating: "bounded", count: 110).joined(separator: " "), refs: [])))
        XCTAssertEqual(Grounding.numbers(in: "shipping takes two three days"), [2, 3])
        XCTAssertTrue(Grounding.supported("Shipping takes two to three days.", evidence: ["shipping takes two three days"]))
        XCTAssertFalse(Grounding.supported("Shipping takes five days.", evidence: ["shipping takes two three days"]))
        XCTAssertEqual(Grounding.numbers(in: "two hundred photos or one and a half gigabytes"), [200, 1.5])
        XCTAssertEqual(Grounding.numbers(in: "October twenty eighth won't work. I'd say November fourth"), [28, 4])
        XCTAssertEqual(Grounding.numbers(in: "lands in two point five, not two point four"), [2.5, 2.4])
        XCTAssertEqual(Grounding.numbers(in: "200 photos or 1.5 GB, v2.4, 1,500 users"), [200, 1.5, 2.4, 1500])
        XCTAssertTrue(Grounding.numbers(in: "a bazillion cutscenes, a billion more").isEmpty)
    }

    func testLinesMayNotInventQuantities() {
        let evidence = ["One more thing the photo upload queue needs a cap two hundred photos or one and a half gigabytes per device oldest first with a banner at the cap"]
        XCTAssertTrue(Grounding.supported("The photo upload queue is capped at 200 photos or 1.5 GB per device, oldest first, with a banner at the cap.", evidence: evidence))
        XCTAssertFalse(Grounding.supported("The photo upload queue is capped at 500 photos per device.", evidence: evidence))
        XCTAssertFalse(Grounding.supported("1 billion left.", evidence: ["you got like a more billion cutscenes left"]))
        XCTAssertFalse(Grounding.supported("Merchandise sales grew across the field level retail stores this quarter.", evidence: ["then let's merge at the field level for checklists"]))
        XCTAssertEqual(Grounding.tidy("with a prototype prototype by Monday"), "with a prototype by Monday")
        XCTAssertEqual(Grounding.tidy("The deadline is November fourth. Then"), "The deadline is November fourth.")
        // A date the speakers ruled out cannot come back as the decision.
        let dates = ["Yes, give me till Monday, but the SQL live migration means QA needs a full week. So October twenty eighth won't work. I'd say November fourth"]
        XCTAssertFalse(Grounding.supported("The team set the ship date to October twenty eighth.", evidence: dates))
        XCTAssertTrue(Grounding.supported("The ship date is November fourth because QA needs a full week; October twenty eighth won't work.", evidence: dates))
        XCTAssertFalse(Grounding.supported("QA cannot complete the work until October twenty eighth.", evidence: dates))
        // Recognized speech without commas: the negation is about the value right after it.
        let android = ["agreed and Android parody lands in two point five not two point four"]
        XCTAssertTrue(Grounding.supported("The Android parody landed in two point five, not two point four.", evidence: android))
        XCTAssertFalse(Grounding.supported("Android parity lands in two point four.", evidence: android))
    }

    // MARK: Commitments

    func testCommitmentsComeFromWhatWasSaid() {
        func chunk(_ id: String, _ speaker: String, _ start: Double, _ text: String) -> TranscriptChunk {
            TranscriptChunk(id: id + "#0", segmentID: id, speaker: speaker, start: start, end: start + 6, text: text)
        }
        let chunks = [
            chunk("a", "Speaker 1", 90, "then let's merge at the field level for checklists and keep last write wins for everything else. Can you prototype that by Monday?"),
            chunk("b", "Speaker 2", 97, "Yes, give me till Monday, but the SQLite migration means QA needs a full week. So October twenty eighth won't work. I'd say November fourth"),
            chunk("c", "Priya", 108, "fine November fourth I'll tell Halvorsen on Friday their contract says offline capture by the end of the year, and they'll be the first of forty beta accounts."),
            chunk("d", "Speaker 2", 118, "One more thing the photo upload queue needs a cap"),
            chunk("e", "Speaker 1", 128, "I'll be honest, I think we're fine")]
        let found = Commitments.find(chunks)
        XCTAssertEqual(found.map(\.task), ["Prototype that by Monday", "Tell Halvorsen on Friday"])
        XCTAssertEqual(found.map(\.owner), [nil, "Priya"])
        XCTAssertTrue(Commitments.needsRephrasing(found[0])); XCTAssertFalse(Commitments.needsRephrasing(found[1]))
        // Rewording may resolve "that", but never move the deadline to another date it heard.
        XCTAssertEqual(Commitments.rephrased("Prototype the field-level checklist merge by Monday.</output>", candidate: found[0]),
                       "Prototype the field-level checklist merge by Monday")
        XCTAssertEqual(Commitments.rephrased("Prototype checklist merge by November fourth", candidate: found[0]), "Prototype that by Monday")
        XCTAssertEqual(Commitments.rephrased("Speaker 2 will prototype the merge by Monday", candidate: found[0]), "Prototype that by Monday")
        XCTAssertEqual(NoteOutput.dedupe([ActionItem(text: "Tell Halvorsen on Friday"), ActionItem(text: "tell Halvorsen Friday")]).count, 1)
    }

    // MARK: Capture

    func testAMicThatCannotOpenNeverCostsTheCall() {
        let refused = CaptureHealth(microphone: .unavailable("com.apple.coreaudio.avfaudio error -308"), systemRequested: true, systemWorking: true)
        XCTAssertTrue(refused.canRecord)
        XCTAssertEqual(refused.degradedMessage, "Recording call audio · your mic isn’t available")
        let nothing = CaptureHealth(microphone: .unavailable("-308"), systemRequested: true, systemWorking: false)
        XCTAssertFalse(nothing.canRecord)
        let silent = CaptureHealth(microphone: .silent(device: "MacBook Pro Microphone"), systemRequested: true, systemWorking: true)
        XCTAssertTrue(silent.canRecord)
        XCTAssertEqual(silent.degradedMessage, "Recording call audio · “MacBook Pro Microphone” is sending only silence")
        XCTAssertNil(CaptureHealth(microphone: .working, systemRequested: true, systemWorking: true).degradedMessage)
    }

    func testDigitalSilenceIsNotAQuietRoom() {
        var meter = SilenceMeter()
        meter.add([Int16](repeating: 0, count: 16_000 * 9))
        XCTAssertTrue(meter.isDigitalSilence())
        var quiet = SilenceMeter()
        quiet.add((0..<(16_000 * 9)).map { Int16($0 % 3 - 1) }) // -90 dBFS hiss is still a working mic
        XCTAssertFalse(quiet.isDigitalSilence())
        var early = SilenceMeter()
        early.add([Int16](repeating: 0, count: 16_000))
        XCTAssertFalse(early.isDigitalSilence(), "one second of zeros is a gap, not a fault")
    }
}
