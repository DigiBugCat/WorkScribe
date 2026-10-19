import XCTest
@testable import WorkScribeCore

final class EchoFilterTests: XCTestCase {
    /// The real recording: two TTS voices through the Mac's speakers, no headphones. Every system
    /// line has a fragmented microphone twin. Before the call, the microphone heard unrelated
    /// speech in the room that never played on this Mac.
    private func fixture() throws -> Meeting {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "tts-echo-segments", withExtension: "json", subdirectory: "Golden"))
        var meeting = Meeting(title: "Offline sync TTS test")
        meeting.segments = try JSONDecoder().decode([Segment].self, from: Data(contentsOf: url))
        return meeting
    }

    func testRealRecordingDropsEveryEchoAndKeepsRoomSpeech() throws {
        var meeting = try fixture()
        let mic = meeting.segments.filter { $0.source == "microphone" }
        let systemText = meeting.segments.filter { $0.source == "system" }.map(\.text)
        let firstSystem = try XCTUnwrap(meeting.segments.filter { $0.source == "system" }.map(\.start).min())
        let roomSpeech = Set(mic.filter { $0.end < firstSystem }.map(\.id))
        XCTAssertEqual(mic.count, 36); XCTAssertEqual(roomSpeech.count, 6)

        let matches = EchoFilter.matches(meeting.segments)
        let moved = meeting.removeEchoes()
        let survivors = meeting.segments.filter { $0.source == "microphone" }
        print("tts echo fixture: \(mic.count) microphone segments -> \(survivors.count) survive; \(moved) echoes removed; \(matches.filter { $0.score == 0 }.count) by context")
        // Every microphone segment during the call was echo; nothing said in the room before it is lost.
        XCTAssertEqual(Set(survivors.map(\.id)), roomSpeech)
        XCTAssertEqual(moved, 30)
        // The system transcript is untouched and the echoes are kept for audit, not deleted.
        XCTAssertEqual(meeting.segments.filter { $0.source == "system" }.map(\.text), systemText)
        XCTAssertEqual(meeting.echoSegments?.count, 30)
        // Evidence that cited an echo now lands on the line it repeated.
        XCTAssertEqual(meeting.resolvedSegmentID("76893BB3-4E97-40A0-9BCD-98DE06BC341D"), "A4BE0F23-6892-4DFB-A6B5-9975A2BFDF88") // "merch at the field level"
        XCTAssertEqual(meeting.resolvedSegmentID("FBF7F962-1075-4F41-AF34-99A60C6B2B14"), "23A265B2-A182-4625-B790-A04EB9E817D5") // "how this are known"
        // Idempotent.
        XCTAssertEqual(meeting.removeEchoes(), 0)
    }

    /// The live test with Apple echo cancellation on: what got through is garbled, and still echo.
    func testResidualEchoAfterCancellationIsRemoved() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "aec-live-segments", withExtension: "json", subdirectory: "Golden"))
        var meeting = Meeting(title: "Offline sync AEC test")
        meeting.segments = try JSONDecoder().decode([Segment].self, from: Data(contentsOf: url))
        XCTAssertEqual(meeting.segments.filter { $0.source == "system" }.count, 7)
        meeting.removeEchoes()
        let kept = meeting.segments.filter { $0.source == "microphone" }.map(\.text)
        XCTAssertEqual(Set(meeting.echoSegments?.map(\.text) ?? []),
                       ["Okay, let's talk about offline sync for Virtu Four",
                        "Friday on John says online that you end up a year and I'll be able to list a plock in the emails"])
        // Fragments long after the call went quiet are not echo; the final recognizer sets them aside.
        XCTAssertEqual(kept, ["fees", "can set", "up cash", "closed albums"])
    }

    func testEchoNoLongerReachesAILineEvidence() throws {
        var meeting = try fixture()
        var note = Note(text: "- lww?", createdAt: 89.978)
        note.id = "lww"
        meeting.notes = [note]
        let before = Chunker.transcript(meeting)
        XCTAssertTrue(before.contains { ["D607054F", "76893BB3", "6D3ED3DD"].contains(where: $0.segmentID.hasPrefix) })
        meeting.removeEchoes()
        let after = Chunker.transcript(meeting)
        let removed = Set((meeting.echoSegments ?? []).map(\.id))
        XCTAssertFalse(after.isEmpty)
        XCTAssertTrue(after.allSatisfy { !removed.contains($0.segmentID) })
        XCTAssertFalse(after.contains { $0.text.lowercased().contains("merch ") })
    }

    func testUserTalkingOverTheCallIsKept() {
        var meeting = Meeting(title: "Over the call")
        let remote = Segment(source: "system", speaker: "system:speaker-1", start: 10, end: 18,
                             text: "Then let's merge at the field level for checklists and keep last write wins for everything else.")
        let echo = Segment(source: "microphone", speaker: "microphone:speaker-1", start: 10.4, end: 13,
                           text: "then let's merch at the field level")
        let user = Segment(source: "microphone", speaker: "microphone:speaker-2", start: 14, end: 16.5,
                           text: "Wait, what about the photo queue budget")
        let yeah = Segment(source: "microphone", speaker: "microphone:speaker-2", start: 17, end: 17.3, text: "yeah")
        meeting.segments = [remote, echo, user, yeah]
        XCTAssertEqual(meeting.removeEchoes(), 1)
        XCTAssertEqual(meeting.segments.map(\.id), [remote.id, user.id, yeah.id])
    }

    func testHeadphonesAndMicOnlyRecordingsAreUntouched() {
        var micOnly = Meeting(title: "In person")
        micOnly.segments = [Segment(source: "microphone", speaker: "microphone:speaker-1", start: 0, end: 3, text: "Ship it on Friday")]
        XCTAssertEqual(micOnly.removeEchoes(), 0)
        var separate = Meeting(title: "Headphones")
        separate.segments = [Segment(source: "system", speaker: "system:speaker-1", start: 0, end: 4, text: "The migration needs a full week of QA"),
                             Segment(source: "microphone", speaker: "microphone:speaker-1", start: 5, end: 7, text: "Then November fourth works for me")]
        XCTAssertEqual(separate.removeEchoes(), 0)
    }

    func testFuzzyWordsTolerateRecognitionErrors() {
        XCTAssertTrue(EchoFilter.similar("merch", "merge"))
        XCTAssertTrue(EchoFilter.similar("counts", "accounts"))
        XCTAssertTrue(EchoFilter.similar("parody", "parity"))
        XCTAssertFalse(EchoFilter.similar("photo", "budget"))
        XCTAssertFalse(EchoFilter.similar("an", "and"))
    }

    /// Speech with no pause long enough to end an utterance stays one hypothesis for a while. Live
    /// lines can quote it, under the id its first segment keeps when it completes.
    func testInProgressSystemSpeechWaitsForFinalization() {
        var meeting = Meeting(title: "Live")
        meeting.setPartial("if it's last write wins an inspector's checklist edits just vanish", source: "system", speaker: "system:speaker-2", span: (80, 88))
        let id = meeting.partialIDs!["system"]!
        XCTAssertTrue(meeting.settledSegments.isEmpty)
        XCTAssertTrue(Chunker.transcript(meeting).isEmpty)
        var note = Note(text: "- lww?", createdAt: 90); note.id = "n"
        meeting.notes = [note]
        XCTAssertTrue(try SelectionFixture.plan(meeting, incremental: true).excerpts.isEmpty)
        meeting.finishPartial([Segment(source: "system", speaker: "system:speaker-2", start: 80, end: 88.9, text: "If it's last write wins, an inspector's checklist edits just vanish.")], source: "system")
        XCTAssertEqual(meeting.segments.first?.id, id, "the evidence anchor survives completion")
        meeting.status = "complete"
        XCTAssertEqual(Chunker.transcript(meeting).map(\.segmentID), [id])
    }

    func testMicrophoneHeldBackOnlyWhileSystemIsMidUtterance() {
        var meeting = Meeting(title: "Live")
        let system = Segment(source: "system", speaker: "system:speaker-1", start: 0, end: 4, text: "Okay let's start")
        let late = Segment(source: "microphone", speaker: "microphone:speaker-1", start: 8, end: 9, text: "offline skin")
        meeting.segments = [system, late]
        XCTAssertEqual(meeting.settledSegments.count, 2)
        meeting.partials["system"] = "okay let's talk about offline sync"
        XCTAssertEqual(meeting.settledSegments.map(\.id), [system.id])
    }
}
