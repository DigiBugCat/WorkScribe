import XCTest
import WorkScribeCore
@testable import WorkScribe

/// Records every pass the scheduler asks for; writes one checked line per note it is given.
private actor PassLog: Enriching {
    var live = 0, final = 0
    func enhance(_ meeting: Meeting, incremental: Bool) async throws -> Enrichment? {
        if incremental { live += 1 } else { final += 1 }
        let plan = incremental ? try SelectionFixture.plan(meeting, incremental: true)
                               : try SelectionFixture.finalPlan(meeting)
        let lines = plan.targets.map { _ in "* **Photo cap:** The photo upload queue needs a cap of two hundred photos per device." }
        var draft = Enrichment.fixture(plan: plan, output: lines.joined(separator: "\n"))
        return draft
    }
}

/// The live app's sequence, without audio hardware: a recording, its meeting note opened and typed
/// into through the document API, the Mac getting busy and recovering, then Stop.
@MainActor final class LiveSessionTests: XCTestCase {
    private func recording() throws -> (AppModel, LocalAPI, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(store: MeetingStore(root: root.appendingPathComponent("Meetings")))
        let ask = AskService(model: model, store: ConversationStore(root: root.appendingPathComponent("Chats")), generator: nil)
        let vault = VaultStore(root: root.appendingPathComponent("Vault"), stateDirectory: root.appendingPathComponent("State"))
        model.retentionService = MeetingRetention(model: model, ask: ask, vault: vault, index: nil, requiresIndex: false)
        var meeting = Meeting(title: "Live")
        meeting.startedAt = Date().addingTimeInterval(-120) // two minutes in, so every segment is inside the session
        meeting.recordingSessions = [RecordingSession(id: "initial", start: 0, sourceOffsets: ["system": 0, "microphone": 0])]
        meeting.sourceOffsets = ["system": 0, "microphone": 0]
        meeting.segments = [
            Segment(source: "system", speaker: "system:speaker-1", start: 10, end: 16, text: "One more thing the photo upload queue needs a cap two hundred photos per device"),
            // Echo that got past cancellation, and noise fragments long after the call went quiet.
            Segment(source: "microphone", speaker: "microphone:speaker-1", start: 10.5, end: 14, text: "the photo upload two hundred photos"),
            Segment(source: "microphone", speaker: "microphone:speaker-1", start: 60, end: 60.4, text: "fees"),
            Segment(source: "microphone", speaker: "microphone:speaker-1", start: 63, end: 63.8, text: "can set")]
        model.meeting = meeting; model.phase = "recording"
        try model.save()
        return (model, LocalAPI(model: model, ask: ask), root)
    }
    /// The plugin's sync: the note typed into the vault file, then PATCHed as the document.
    private func type(_ text: String, at: Double, api: LocalAPI, model: AppModel) async throws {
        let id = model.meeting!.id
        if model.meeting?.document == nil {
            let opened = await api.respond(.openDocument(id), HTTPRequest(method: "POST", path: "/v1/meetings/\(id)/document"))
            XCTAssertEqual(opened.status, 200)
        }
        var document = model.meeting!.document!
        var source = document.source.hasSuffix("- ") ? String(document.source.dropLast(2)) : document.source
        let from = (source as NSString).length
        source += text
        document.blocks.append(.init(id: UUID().uuidString, from: from, to: (source as NSString).length, text: text, at: at, section: ""))
        source += "\n"; document.source = source
        try source.write(toFile: document.path, atomically: true, encoding: .utf8)
        let synced = await api.respond(.syncDocument(id), HTTPRequest(method: "PATCH", path: "/v1/meetings/\(id)/document", body: try JSONEncoder().encode(document)))
        XCTAssertEqual(synced.status, 200, String(decoding: synced.body, as: UTF8.self))
    }

    /// Live lines resume as soon as the transcript is close enough, not only at full recovery, and
    /// without waiting for another transcript event (after the call goes quiet there are none).
    func testLiveLinesResumeWhenTheMacStopsBeingBusy() async throws {
        let (model, api, root) = try recording(); defer { try? FileManager.default.removeItem(at: root) }
        let log = PassLog(), scheduler = NoteEnhancementScheduler.shared
        let old = (scheduler.enhancer, scheduler.delay, scheduler.minimumInterval)
        scheduler.enhancer = log; scheduler.delay = 1_000_000; scheduler.minimumInterval = 0
        defer { (scheduler.enhancer, scheduler.delay, scheduler.minimumInterval) = old }
        var lag = 9.0
        model.lagProbe = { lag }
        model.updateRecordingPressure()
        XCTAssertTrue(model.liveAIPaused)
        try await type("- photo cap", at: 17, api: api, model: model)
        try await Task.sleep(nanoseconds: 50_000_000)
        var passes = await log.live
        XCTAssertEqual(passes, 0, "busy: the note waits")
        lag = 3 // still behind, but no longer too busy for AI lines
        model.updateRecordingPressure()
        XCTAssertEqual(model.recordingPressure, .screenPaused)
        for _ in 0..<100 where (model.meeting?.notes?.first?.line.text == nil) { try await Task.sleep(nanoseconds: 10_000_000) }
        passes = await log.live
        XCTAssertEqual(passes, 1)
        XCTAssertEqual(model.meeting?.notes?.first?.line.text, "**Photo cap:** The photo upload queue needs a cap of two hundred photos per device.")
    }

    /// Stop flushes note work without replacing the settled transcript, including short mic fragments.
    func testStopRunsTheFinalPassWhenTheMicTrackIsSilent() async throws {
        let (model, api, root) = try recording(); defer { try? FileManager.default.removeItem(at: root) }
        let log = PassLog(), scheduler = NoteEnhancementScheduler.shared
        let old = scheduler.enhancer
        scheduler.enhancer = log; defer { scheduler.enhancer = old }
        try await type("- photo cap", at: 17, api: api, model: model)
        model.consume(["type": "transcript.completed", "transcript": ""], source: "system")
        let before = model.meeting!.segments.filter { $0.text != "the photo upload two hundred photos" }
        await model.stop()
        let meeting = try XCTUnwrap(model.meeting)
        XCTAssertEqual(model.phase, "ready", model.message)
        XCTAssertEqual(model.message, "Recording saved on this Mac")
        XCTAssertNil(meeting.transcriptPolishedForEnd)
        let finals = await log.final
        XCTAssertEqual(finals, 1)
        XCTAssertNotNil(meeting.notes?.first?.line.text)
        XCTAssertEqual(meeting.notes?.first?.line.state, .settled)
        XCTAssertNil(meeting.actionItems, "Optional synthesis runs after line settlement")
        XCTAssertEqual(meeting.segments.map(\.id), before.map(\.id))
        XCTAssertEqual(meeting.segments.map(\.text), before.map(\.text))
        XCTAssertNil(meeting.unheardSegments)
        XCTAssertTrue(meeting.segments.contains { $0.text == "fees" })
        XCTAssertEqual(meeting.echoSegments?.map(\.text), ["the photo upload two hundred photos"])
        XCTAssertTrue(EchoFilter.matches(meeting.segments).isEmpty)
    }

}
