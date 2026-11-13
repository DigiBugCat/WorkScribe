import XCTest
import WorkScribeCore
@testable import WorkScribe

/// Counterexamples from `formal/tla/Recording.tla` and `NoteScheduler.tla`, replayed on the real
/// `AppModel` and `NoteEnhancementScheduler`. Each test is one trace the model checker found; the
/// comment gives the property it violates. A "resume" here is what `start(resuming:)` does to the
/// model once it has claimed the meeting (`Meeting.resume()`, phase "recording"), without audio.
@MainActor final class RecordingRaceTests: XCTestCase {
    /// The first call waits until released; later calls answer at once.
    private actor GatedEnhancer: Enriching {
        private(set) var waiting = false
        private(set) var calls = 0
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?
        func enhance(_ meeting: Meeting, incremental: Bool) async throws -> Enrichment? {
            calls += 1
            guard !released else { return nil }
            waiting = true
            await withCheckedContinuation { continuation = $0 }
            return nil
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }
    private struct NoEnhancement: Enriching {
        func enhance(_ meeting: Meeting, incremental: Bool) async throws -> Enrichment? { nil }
    }

    private var root: URL!
    private var previous: (any Enriching)!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("race-" + UUID().uuidString)
        previous = NoteEnhancementScheduler.shared.enhancer
    }
    override func tearDown() async throws {
        NoteEnhancementScheduler.shared.enhancer = previous
        try? FileManager.default.removeItem(at: root)
    }

    private func recording() throws -> AppModel {
        let model = AppModel(store: MeetingStore(root: root))
        var meeting = Meeting(title: "Race")
        meeting.notes = [Note(text: "release", createdAt: 1)]
        meeting.segments = [Segment(source: "system", speaker: "system:speaker-1", start: 1, end: 3, text: "Release ships Friday.")]
        model.meeting = meeting; model.phase = "recording"; try model.save()
        return model
    }
    private func resume(_ model: AppModel) throws {
        try model.meeting!.resume(); model.phase = "recording"; try model.save()
    }

    /// R4, "stop is not swallowed": Stop, Resume during the final pass, Stop again. The second Stop joined
    /// the first one's task, which gives up once it sees the resume, and returned with the recording running.
    func testASecondStopAfterAResumeStopsTheResumedRecording() async throws {
        let gate = GatedEnhancer(); NoteEnhancementScheduler.shared.enhancer = gate
        let model = try recording()
        let first = Task { await model.stop() }
        while !(await gate.waiting) { await Task.yield() }
        XCTAssertEqual(model.phase, "finalizing")
        try resume(model)
        let second = Task { await model.stop() }
        for _ in 0..<5 { await Task.yield() }
        await gate.release()
        await first.value; await second.value
        XCTAssertNotEqual(model.phase, "recording", "the second Stop must stop the recording it was pressed on")
        XCTAssertNotNil(model.meeting?.endedAt)
        XCTAssertEqual(model.meeting?.status, "complete")
    }

    /// R11, "a stop only stops the session it was asked of": Stop, Stop again while the first is finishing,
    /// then Resume. The second Stop was pressed on a meeting that was already stopping; once it had waited
    /// out the first, it found a recording running (the resumed one) and ended it. This path was opened by
    /// the fix for R4 and found when the model was re-run against that fix.
    func testAStopPressedDuringTheFinalPassDoesNotEndARecordingResumedSince() async throws {
        let gate = GatedEnhancer(); NoteEnhancementScheduler.shared.enhancer = gate
        let model = try recording()
        let first = Task { await model.stop() }
        while !(await gate.waiting) { await Task.yield() }
        XCTAssertEqual(model.phase, "finalizing")
        let second = Task { await model.stop() }
        for _ in 0..<5 { await Task.yield() }
        try resume(model)
        await gate.release()
        await first.value; await second.value
        XCTAssertEqual(model.phase, "recording", "a Stop from before the resume must not end the resumed recording")
        XCTAssertNil(model.meeting?.endedAt)
        XCTAssertEqual(model.meeting?.status, "recording")
    }

    /// R5a: the first Stop is past its "was this resumed?" check and waiting on the last step when the
    /// meeting is resumed. Its tail then declared the app idle ("ready") while the meeting was recording.
    func testTheTailOfAnOldStopDoesNotDeclareAResumedRecordingReady() async throws {
        NoteEnhancementScheduler.shared.enhancer = NoEnhancement()
        let model = try recording()
        let stopping = Task { await model.stop() }
        while model.finalizationProgress < 0.9 { await Task.yield() }
        try XCTSkipUnless(model.phase == "finalizing", "the window between the last check and the tail was not hit on this run")
        try resume(model)
        await stopping.value
        XCTAssertEqual(model.phase, "recording", "an old stop must not mark a resumed recording as finished")
        XCTAssertNil(model.meeting?.endedAt)
        XCTAssertEqual(model.meeting?.status, "recording")
    }

    /// N4, "a superseded pass never applies": the final pass found nothing to write and was about to settle
    /// every line when the meeting was resumed. It settled the lines of a meeting that is recording again.
    func testAFinalPassThatFoundNothingDoesNotSettleAResumedMeeting() async throws {
        let gate = GatedEnhancer()
        let scheduler = NoteEnhancementScheduler(); scheduler.enhancer = gate
        let model = try recording()
        model.meeting!.status = "complete"; model.meeting!.endedAt = Date(); model.phase = "finalizing"; try model.save()
        let pass = Task { await scheduler.finish(model.meeting!.id, model: model) }
        while !(await gate.waiting) { await Task.yield() }
        try resume(model)
        await gate.release()
        _ = await pass.value
        XCTAssertEqual(model.meeting?.notes?.first?.line.state, .listening, "a line of a meeting that is recording is not settled")
    }

    /// N7, "abandoned work is asked for again": the same trace, one step further. The pass that gave up at
    /// the resume had taken the jot with it, and nothing asked again: the inputs it was scheduled for had
    /// not changed, so the jot waited for the next line of speech or the next edit.
    func testAPassThatGivesUpAtAResumeLeavesItsWorkToBeAskedForAgain() async throws {
        let gate = GatedEnhancer()
        let scheduler = NoteEnhancementScheduler(); scheduler.enhancer = gate
        let model = try recording()
        model.meeting!.status = "complete"; model.meeting!.endedAt = Date(); model.phase = "finalizing"; try model.save()
        let pass = Task { await scheduler.finish(model.meeting!.id, model: model) }
        while !(await gate.waiting) { await Task.yield() }
        try resume(model)
        await gate.release()
        _ = await pass.value
        for _ in 0..<200 { if await gate.calls >= 2 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let calls = await gate.calls
        XCTAssertEqual(calls, 2, "the resumed meeting's jot is looked at again without new speech or an edit")
    }
}
