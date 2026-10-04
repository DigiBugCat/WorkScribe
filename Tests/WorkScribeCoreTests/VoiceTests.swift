import XCTest
@testable import WorkScribeCore

final class VoiceTests: XCTestCase {
    func testAmbiguityAndInvalidVectorsAreRejected() {
        var first = VoiceProfile(name: "First"), second = VoiceProfile(name: "Second")
        first.samples = [VoiceSample(meetingID: "old", segmentID: "a", vector: [1,0])]
        second.samples = [VoiceSample(meetingID: "old", segmentID: "b", vector: [0.99,0.01])]
        XCTAssertNil(VoiceMatching.suggest(vectors: [[1,0]], profiles: [first, second], excluding: "new"))
        XCTAssertNil(VoiceMatching.suggest(vectors: [[0,1]], profiles: [first], excluding: "new"))
        XCTAssertNil(VoiceMatching.suggest(vectors: [[1,0]], profiles: [first], excluding: "old"))
        XCTAssertNil(VoiceMatching.suggest(vectors: [[Float.nan,0]], profiles: [first], excluding: "new"))
        XCTAssertNotNil(VoiceMatching.suggest(vectors: [[1,0]], profiles: [first], excluding: "new"))
        XCTAssertNil(VoiceMatching.suggest(vectors: [[1,0],[0,1]], profiles: [first], excluding: "new"))
    }
    func testLegacyAudioAndOverlapsCannotTrain() {
        var meeting = Meeting(title: "Test")
        let a = Segment(source: "system", speaker: "system:speaker-1", start: 1, end: 5, text: "Test")
        meeting.segments = [a]
        XCTAssertFalse(VoiceMatching.eligible(a, in: meeting))
        meeting.sourceOffsets = ["system": 0]
        XCTAssertTrue(VoiceMatching.eligible(a, in: meeting))
        meeting.segments.append(Segment(source: "system", speaker: "system:speaker-2", start: 4, end: 6, text: "Overlap"))
        XCTAssertFalse(VoiceMatching.eligible(a, in: meeting))
    }
    func testMCPExposesConfirmedNamesWithoutBiometrics() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        var meeting = Meeting(title: "Test")
        let segment = Segment(source: "system", speaker: "system:speaker-1", start: 0, end: 4, text: "Hello")
        meeting.segments = [segment]
        meeting.speakerAssignments = [segment.speaker: SpeakerAssignment(name: "Alex", profileID: "private", remember: true)]
        try store.save(meeting)
        let server = MCPServer(store: store)
        let value = try server.call("get_transcript", args: ["meeting_id": meeting.id])
        let data = try JSONSerialization.data(withJSONObject: value)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("Alex")); XCTAssertTrue(text.contains("system:speaker-1"))
        XCTAssertFalse(text.contains("private")); XCTAssertFalse(text.contains("vector"))
    }
}
