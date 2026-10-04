import XCTest
@testable import WorkScribeCore

final class CoreTests: XCTestCase {
    var folder: URL!
    var store: MeetingStore!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = MeetingStore(root: folder)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }
    func testAtomicSnapshotRoundTripAndPathTraversal() throws {
        var meeting = Meeting(title: "Test")
        meeting.partials = ["microphone": "provisional"]
        try store.save(meeting)
        XCTAssertEqual(try store.load(meeting.id).partials["microphone"], "provisional")
        meeting.partials = [:]; meeting.status = "complete"
        try store.save(meeting)
        XCTAssertEqual(store.list().count, 1)
        XCTAssertEqual(try store.load(meeting.id).status, "complete")
        XCTAssertThrowsError(try store.load("../../etc/passwd"))
    }
    func testSpeakerChangesAndSourceNamespace() {
        let event: [String: Any] = ["words": [
            ["word": "Ship", "start": 0.1, "end": 0.3, "speaker": 1],
            ["word": "Friday", "start": 0.4, "end": 0.8, "speaker": 1],
            ["word": "Agreed", "start": 0.9, "end": 1.3, "speaker": 2]]]
        let segments = TranscriptParser.segments(event: event, source: "system", offset: 2, fallbackStart: 0)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "Ship Friday")
        XCTAssertEqual(segments[0].speaker, "system:speaker-1")
        XCTAssertEqual(segments[0].start, 2.1, accuracy: 0.001)
        XCTAssertEqual(segments[1].speaker, "system:speaker-2")
    }
    func testMCPReadsUpdatesAndSeparatesDrafts() throws {
        let server = MCPServer(store: store)
        let initResponse = server.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-11-25"]])!
        XCTAssertEqual((initResponse["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-11-25")
        var meeting = Meeting(title: "Decisions")
        meeting.segments = [Segment(source: "microphone", speaker: "microphone:speaker-1", start: 4, end: 6, text: "Ship on Friday.")]
        meeting.partials = ["microphone": "maybe Monday"]
        try store.save(meeting)
        func call(_ name: String, _ args: [String: Any] = [:]) throws -> [String: Any] {
            let response = server.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": name, "arguments": args]])!
            let result = response["result"] as! [String: Any]
            XCTAssertEqual(result["isError"] as? Bool, false)
            let text = (result["content"] as! [[String: Any]])[0]["text"] as! String
            return try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        }
        XCTAssertEqual(try call("get_live_transcript")["active"] as? Bool, true)
        let search = try call("search_transcripts", ["query": "FRIDAY"])
        XCTAssertEqual((search["hits"] as? [[String: Any]])?.first?["segment_id"] as? String, meeting.segments[0].id)
        XCTAssertEqual((try call("search_transcripts", ["query": "Monday"])["hits"] as? [Any])?.count, 0)
        meeting.status = "complete"; try store.save(meeting)
        XCTAssertEqual(try call("get_live_transcript")["active"] as? Bool, false)
        let page = try call("get_transcript", ["meeting_id": meeting.id, "offset": 100, "limit": 1])
        XCTAssertEqual((page["segments"] as? [Any])?.count, 0)
    }
    func testProtocolFailures() {
        let server = MCPServer(store: store)
        XCTAssertNil(server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]))
        let response = server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        XCTAssertEqual((response?["error"] as? [String: Any])?["code"] as? Int, -32002)
    }
    func testPartialCaptionsDoNotGuessTheSpeaker() {
        XCTAssertNil(TranscriptParser.partialSpeaker(event: ["transcript": "hello"], source: "system"))
        XCTAssertEqual(TranscriptParser.partialSpeaker(event: ["words": [["word": "hello", "speaker": 2]]], source: "system"), "system:speaker-2")
        XCTAssertNil(TranscriptParser.partialSpeaker(event: ["words": [["word": "hello", "speaker": 1], ["word": "yes", "speaker": 2]]], source: "system"))
        XCTAssertNil(TranscriptParser.partialSpeaker(event: ["words": [["word": "hello", "speaker": 1], ["word": "there"]]], source: "system"))
    }
}
