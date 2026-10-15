import XCTest
@testable import WorkScribeCore

final class LocalAPITests: XCTestCase {
    func request(_ method: String, _ path: String, headers: [String: String] = [:], body: String = "") -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\n"
        var all = headers
        if !body.isEmpty { all["Content-Length"] = String(body.utf8.count) }
        for (key, value) in all { head += "\(key): \(value)\r\n" }
        return Data((head + "\r\n" + body).utf8)
    }

    // MARK: Parsing

    func testParsesRequestLineHeadersQueryAndBody() {
        let data = request("POST", "/v1/search?limit=5&x=a%20b", headers: ["Host": "127.0.0.1:8123", "Authorization": "Bearer t"], body: #"{"query":"q"}"#)
        guard case .complete(let parsed) = HTTPParser.parse(data, maxBody: 1024) else { return XCTFail() }
        XCTAssertEqual(parsed.method, "POST"); XCTAssertEqual(parsed.path, "/v1/search")
        XCTAssertEqual(parsed.query, ["limit": "5", "x": "a b"])
        XCTAssertEqual(parsed.headers["authorization"], "Bearer t")
        XCTAssertEqual(String(decoding: parsed.body, as: UTF8.self), #"{"query":"q"}"#)
    }

    func testIncompleteOversizedAndMalformedRequests() {
        let full = request("POST", "/v1/ask", headers: ["Host": "localhost"], body: "0123456789")
        XCTAssertEqual(HTTPParser.parse(full.prefix(full.count - 3), maxBody: 100), .incomplete)
        XCTAssertEqual(HTTPParser.parse(Data("GET /v1/status HTTP/1.1\r\nHost: x".utf8), maxBody: 100), .incomplete)
        XCTAssertEqual(HTTPParser.parse(full, maxBody: 5), .invalid(status: 413, reason: "Body over 5 bytes"))
        if case .invalid(let status, _) = HTTPParser.parse(Data("NONSENSE\r\n\r\n".utf8), maxBody: 10) { XCTAssertEqual(status, 400) } else { XCTFail() }
        if case .invalid(let status, _) = HTTPParser.parse(request("POST", "/v1/ask", headers: ["Transfer-Encoding": "chunked"]), maxBody: 10) {
            XCTAssertEqual(status, 400)
        } else { XCTFail() }
    }

    // MARK: Guard

    func testHostTokenAndOriginChecks() {
        XCTAssertTrue(APIGuard.isLoopbackHost("127.0.0.1:5000"))
        XCTAssertTrue(APIGuard.isLoopbackHost("localhost"))
        XCTAssertTrue(APIGuard.isLoopbackHost("[::1]:5000"))
        XCTAssertFalse(APIGuard.isLoopbackHost("evil.example"))
        XCTAssertFalse(APIGuard.isLoopbackHost("127.0.0.1.evil.example:80"))
        XCTAssertFalse(APIGuard.isLoopbackHost("localhost:abc"))
        XCTAssertFalse(APIGuard.isLoopbackHost(nil))

        let token = APIGuard.randomToken()
        XCTAssertEqual(token.count, 64)
        let good = HTTPRequest(method: "GET", path: "/v1/status", headers: ["host": "127.0.0.1:1", "authorization": "Bearer \(token)"])
        XCTAssertNil(APIGuard.check(good, token: token))
        var wrong = good; wrong.headers["authorization"] = "Bearer nope"
        XCTAssertEqual(APIGuard.check(wrong, token: token)?.status, 401)
        var missing = good; missing.headers["authorization"] = nil
        XCTAssertEqual(APIGuard.check(missing, token: token)?.status, 401)
        var rebinding = good; rebinding.headers["host"] = "attacker.test:1"
        XCTAssertEqual(APIGuard.check(rebinding, token: token)?.status, 403)
        var otherOrigin = good; otherOrigin.headers["origin"] = "https://example.com"
        XCTAssertEqual(APIGuard.check(otherOrigin, token: token)?.status, 403)
        var obsidian = good; obsidian.headers["origin"] = "app://obsidian.md"
        XCTAssertNil(APIGuard.check(obsidian, token: token))
        XCTAssertEqual(APIGuard.cors(obsidian)["Access-Control-Allow-Origin"], "app://obsidian.md")
        XCTAssertEqual(APIGuard.cors(obsidian)["Access-Control-Allow-Headers"], "Authorization, Content-Type")
        XCTAssertTrue(APIGuard.cors(good).isEmpty)
        XCTAssertEqual(APIGuard.preflight(obsidian).status, 204)
        XCTAssertEqual(APIGuard.preflight(otherOrigin).status, 403)
    }

    func testConfigFileIsPrivate() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("api-\(UUID().uuidString)/api.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try APIConfig(port: 4242, token: "abc").write(to: url)
        try APIConfig(port: 4243, token: "def").write(to: url)
        let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), #"{"port":4243,"token":"def","version":1}"#)
    }

    // MARK: Routing

    func testRoutes() {
        func route(_ method: String, _ path: String) -> APIRoute? { try? APIRoute.match(method: method, path: path).get() }
        XCTAssertEqual(route("GET", "/v1/status"), .status)
        XCTAssertEqual(route("POST", "/v1/recording/start"), .startRecording)
        XCTAssertEqual(route("POST", "/v1/recording/stop"), .stopRecording)
        XCTAssertEqual(route("GET", "/v1/meetings"), .meetings)
        XCTAssertEqual(route("GET", "/v1/meetings/abc"), .meeting("abc"))
        XCTAssertEqual(route("POST", "/v1/meetings/abc/notes"), .addNote(meetingID: "abc"))
        XCTAssertEqual(route("PATCH", "/v1/meetings/abc/notes/n1"), .editNote(meetingID: "abc", noteID: "n1"))
        XCTAssertEqual(route("GET", "/v1/events"), .events)
        XCTAssertEqual(route("POST", "/v1/ask"), .ask)
        XCTAssertEqual(route("POST", "/v1/search"), .search)
        XCTAssertEqual(route("POST", "/v1/attachments"), .attachments)
        XCTAssertEqual(APIRoute.match(method: "GET", path: "/v1/ask"), .failure(.methodNotAllowed))
        XCTAssertEqual(APIRoute.match(method: "GET", path: "/v2/status"), .failure(.notFound))
        XCTAssertEqual(APIRoute.match(method: "GET", path: "/v1/nope"), .failure(.notFound))
    }

    // MARK: Shapes

    func fixture() -> Meeting {
        var meeting = Meeting(title: "Offline sync")
        meeting.startedAt = Date(timeIntervalSince1970: 1_790_000_000)
        meeting.endedAt = meeting.startedAt.addingTimeInterval(600)
        meeting.status = "complete"
        meeting.segments = [
            Segment(source: "system", speaker: "system:speaker-1", start: 10, end: 20, text: "We move v2.4 to November fourth."),
            Segment(source: "microphone", speaker: "microphone:speaker-1", start: 400, end: 410, text: "I will email Halvorsen by Friday."),
        ]
        meeting.speakerAssignments = ["system:speaker-1": SpeakerAssignment(name: "Priya")]
        meeting.partials = ["system": "and the photo cap"]
        return meeting
    }

    func testMeetingDetailShape() throws {
        var meeting = fixture()
        let chunks = APIShapes.chunkMap(meeting)
        let near = chunks.values.first { $0.start < 100 }!, far = chunks.values.first { $0.start > 100 }!
        var note = Note(text: "v2.4 → nov 4\ntodo update PRD", createdAt: 30)
        note.enhanced = "Release moved to Nov 4."; note.enhancedFrom = note.text; note.excerptRefs = [near.id, far.id]
        meeting.notes = [note]
        meeting.actionItems = [ActionItem(owner: "Priya", text: "update PRD", due: "2026-10-16")]
        meeting.missedTopics = [MissedTopic(topic: "Halvorsen", text: "You'll email them.", excerptRefs: [far.id])]
        var conversation = Conversation(title: "q", scopeMeetingID: meeting.id)
        conversation.messages = [AskMessage(role: .user, text: "When?"),
                                 AskMessage(role: .assistant, text: "Nov 4 [1].", citations: [
                                    AskCitation(number: 1, moment: AskMoment(id: "c", sourceKind: "meeting", ref: meeting.id, title: meeting.title,
                                                                             kind: "meetingSegment", start: 10, speakers: ["Priya"], text: "x"))])]
        let detail = APIShapes.detail(meeting, conversations: [conversation, Conversation(title: "other")], attachments: [])
        XCTAssertEqual(detail.meeting.duration, 600)
        XCTAssertEqual(detail.meeting.speakers, ["Priya", "Speaker 1"])
        XCTAssertEqual(detail.segments.map(\.final), [true, true, false])
        XCTAssertEqual(detail.segments.last?.text, "and the photo cap")
        XCTAssertEqual(detail.notes.first?.excerpts.map(\.id), ["E1", "E2"])
        XCTAssertEqual(detail.notes.first?.excerpts.map(\.hollow), [false, true], "the 06:40 excerpt is outside the typing window")
        XCTAssertEqual(detail.notes.first?.state, "done")
        XCTAssertEqual(detail.missedTopics.first?.excerpts.first?.id, "E1")
        XCTAssertEqual(detail.actionItems.map(\.text), ["update PRD"])
        XCTAssertEqual(detail.answers.map(\.answer), ["Nov 4 [1]."])
        XCTAssertEqual(detail.answers.first?.citations.first?.link, "workscribe://meeting/\(meeting.id)?t=10.0")

        let json = try JSONSerialization.jsonObject(with: APIJSON.encoder.encode(detail)) as! [String: Any]
        XCTAssertEqual(Set(json.keys), ["meeting", "segments", "notes", "missedTopics", "actionItems", "answers", "attachments", "clips", "endedAt"])
        let summary = json["meeting"] as! [String: Any]
        XCTAssertEqual(summary["startedAt"] as? String, "2026-09-21T14:13:20Z")
    }

    func testStatusAndMomentJSON() throws {
        let status = APIStatus(recording: true, phase: "recording", meetingId: "m", title: "T", startedAt: nil, elapsed: 12,
                               sources: .init(mic: true, system: false, screen: true), permissions: .init(screenRecording: true, microphone: true),
                               warming: false, message: nil, model: .init(provider: "openai", name: "gpt-5.4-mini"))
        let json = try JSONSerialization.jsonObject(with: APIJSON.encoder.encode(status)) as! [String: Any]
        XCTAssertEqual((json["sources"] as? [String: Bool])?["screen"], true)
        XCTAssertEqual((json["model"] as? [String: String])?["provider"], "openai")
        var file = AskMoment(id: "x", sourceKind: "file", ref: "/docs/MSA.pdf", title: nil, kind: "document", page: 14, text: "terms")
        file.thumbnail = nil
        let moment = APIMoment(file, number: 2)
        XCTAssertEqual(moment.path, "/docs/MSA.pdf"); XCTAssertNil(moment.meetingId)
        XCTAssertEqual(moment.link, "workscribe://file?path=/docs/MSA.pdf&page=14")
        XCTAssertEqual(moment.title, "MSA.pdf"); XCTAssertEqual(moment.number, 2)
    }

    func testWireEditsAndStableTranscriptIdentity() throws {
        let edit = try APIJSON.decoder.decode(APINotePatch.self, from: Data(#"{"enhanced":{"topic":"Release.","text":"My exact edit."}}"#.utf8))
        XCTAssertEqual(edit.enhanced?.text, "My exact edit.")
        XCTAssertThrowsError(try APIJSON.decoder.decode(APINotePatch.self, from: Data(#"{"text":"x","enhanced":{"topic":"","text":"y"}}"#.utf8)))
        var meeting = fixture()
        meeting.setPartial("first", source: "system", speaker: nil)
        let id = APIShapes.segments(meeting).last!.id
        meeting.setPartial("first phrase", source: "system", speaker: nil)
        XCTAssertEqual(APIShapes.segments(meeting).last!.id, id)
        meeting.finishPartial([Segment(source: "system", speaker: "system:unknown", start: 500, end: 501, text: "First phrase.")], source: "system")
        XCTAssertEqual(meeting.segments.last?.id, id)
        meeting.setPartial("next", source: "system", speaker: nil)
        XCTAssertNotEqual(APIShapes.segments(meeting).last!.id, id)
        XCTAssertEqual(APIShapes.searchKinds(["meeting", "pdf", "clip"]), [.meetingSegment, .document, .clip])
    }

    func testUserEnhancementSurvivesAnInflightPassAndPersistence() throws {
        var meeting = fixture()
        var note = Note(text: "release", createdAt: 30)
        meeting.notes = [note]
        let plan = try NotePlanner.plan(meeting, matcher: LexicalMatcher(), incremental: true, missedTopics: false)
        note.editEnhancement(.init(topic: "Release.", text: "My exact edit."))
        let saved = try APIJSON.decoder.decode(Note.self, from: APIJSON.encoder.encode(note))
        let result = NoteEnhancement.apply("- **Release:** Automatically rewritten.", plan: plan, to: [saved])
        XCTAssertEqual(result.notes[0].enhanced, "**Release.** My exact edit.")
        XCTAssertFalse(result.notes[0].isStale)
        let shape = APIShapes.note(saved, meeting: meeting, chunks: [:], blockId: "e1")
        XCTAssertEqual(shape.enhanced?.text, "My exact edit.")
        XCTAssertEqual(shape.blockId, "e1")
        XCTAssertEqual(shape.state, "done")
    }

    func testSSEFraming() {
        let text = String(decoding: SSE.event("token", ["text": "Hi"], id: 3), as: UTF8.self)
        XCTAssertEqual(text, "id: 3\nevent: token\ndata: {\"text\":\"Hi\"}\n\n")
    }

    func testResponseSerialization() {
        let data = HTTPResponse.json(["ok": true]).serialized()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 11\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{\"ok\":true}"))
    }

    // MARK: OpenAI Responses

    func testOpenAIRequestIsBoundedAndPrivate() throws {
        let long = String(repeating: "transcript words ", count: 5_000)
        let moments = (0..<12).map { AskMoment(id: "\($0)", sourceKind: "meeting", ref: "m", title: "T", kind: "meetingSegment", start: Double($0), text: long) }
        let prompt = AskPrompt.build(question: "What moved?", moments: moments)
        let request = try OpenAIResponses.request(prompt, model: "gpt-5.4-mini", apiKey: "sk-test")
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "gpt-5.4-mini")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["instructions"] as? String, AskPrompt.instructionText)
        let input = ((body["input"] as! [[String: Any]])[0]["content"] as! [[String: Any]])[0]["text"] as! String
        XCTAssertLessThanOrEqual(input.count, OpenAIResponses.maxInputCharacters + 1)
        XCTAssertTrue(input.hasSuffix("Question: What moved?"))
        XCTAssertLessThan(input.count, long.count, "never the whole transcript")
    }

    func testOpenAIStreamParsing() {
        let fixture = """
        event: response.created
        data: {"type":"response.created","response":{"id":"resp_1"}}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"Nov 4 "}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"[1]."}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_1","status":"completed"}}
        """
        let events = fixture.split(separator: "\n").compactMap { OpenAIResponses.parse(line: String($0)) }
        XCTAssertEqual(events, [.ignored, .delta("Nov 4 "), .delta("[1]."), .completed])
        XCTAssertEqual(OpenAIResponses.parse(data: #"{"type":"response.failed","response":{"error":{"message":"boom"}}}"#), .failed("boom"))
        XCTAssertEqual(OpenAIResponses.parse(data: #"{"type":"error","message":"bad"}"#), .failed("bad"))
        XCTAssertEqual(OpenAIResponses.parse(data: #"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#), .completed)
        XCTAssertEqual(OpenAIResponses.errorMessage(Data(#"{"error":{"message":"quota"}}"#.utf8), status: 429), "quota")
        XCTAssertTrue(OpenAIResponses.errorMessage(Data(), status: 401).contains("API key"))
    }
}
