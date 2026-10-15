import XCTest
import WorkScribeCore
@testable import WorkScribe

private actor BatchFixture: BatchTranscribing {
    var calls = 0
    var waiting = false
    var suspend = false
    var continuation: CheckedContinuation<Void, Never>?
    init(suspend: Bool = false) { self.suspend = suspend }
    func transcribe(url: URL, offset: Double, progress: @escaping @Sendable (Double) async throws -> Void) async throws -> [TranscriptWord] {
        calls += 1
        if suspend { waiting = true; await withCheckedContinuation { continuation = $0 } }
        try await progress(1)
        return [.init(text: "Hokkaido", start: offset + 2, end: offset + 3), .init(text: "reservations.", start: offset + 3, end: offset + 4)]
    }
    func release() { continuation?.resume(); continuation = nil }
}
private actor PolishedNotesFixture: NoteEnhancing {
    var text = ""
    func enhance(_ meeting: Meeting, incremental: Bool, missedTopics: Bool) async throws -> NoteDraft? {
        text = meeting.segments.map(\.text).joined(separator: " ")
        let plan = try NotePlanner.plan(meeting, incremental: incremental, missedTopics: missedTopics)
        return NoteDraft(plan: plan, output: "* **Reservations:** Hokkaido requires reservations.")
    }
}
private struct DroppedLineFixture: NoteEnhancing {
    func enhance(_ meeting: Meeting, incremental: Bool, missedTopics: Bool) async throws -> NoteDraft? {
        NoteDraft(plan: try NotePlanner.plan(meeting, incremental: incremental, missedTopics: missedTopics), output: "")
    }
}
private actor NoteRequests {
    var values: [AskPrompt] = []
    func append(_ prompt: AskPrompt) { values.append(prompt) }
}
private struct CloudNoteFixture: AnswerGenerator {
    let requests: NoteRequests
    var displayName: String { "Cloud fixture" }
    var provider: String { "openai" }
    var modelName: String { "fixture" }
    var isAvailable: Bool { true }
    func stream(_ prompt: AskPrompt) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await requests.append(prompt)
                continuation.yield("* **Reservations:** Hokkaido requires reservations.\n</output>")
                continuation.finish()
            }
        }
    }
}

@MainActor final class TranscriptPolisherTests: XCTestCase {
    func testConfiguredProviderKeepsSourceDataOutOfInstructionsAndReportsLocation() async throws {
        var meeting = Meeting(title: "Fixture")
        meeting.notes = [Note(text: "Hokkaido reservations", createdAt: 2)]
        meeting.segments = [Segment(source: "system", speaker: "system:speaker-1", start: 1, end: 3, text: "Hokkaido requires reservations.")]
        let requests = NoteRequests()
        let enhancer = NoteEnhancer(generator: CloudNoteFixture(requests: requests))
        let draft = try await enhancer.enhance(meeting, incremental: false, missedTopics: true)
        XCTAssertEqual(draft?.location, "Cloud")
        let sent = await requests.values
        XCTAssertEqual(sent.count, 1)
        XCTAssertFalse(sent[0].instruction.contains("Hokkaido"))
        XCTAssertTrue(sent[0].sources.contains("Hokkaido requires reservations."))
        XCTAssertLessThan(sent[0].sources.count, OpenAIResponses.maxInputCharacters)
    }
    func testLocalFallbackCannotTurnGarbledCountsOrAdjacentFactsIntoClaims() throws {
        var meeting = Meeting(title: "Game")
        meeting.notes = ["- how many cutscenes left?", "- needs compass + food", "- car broken earlier?"].map { Note(text: $0, createdAt: 455) }
        meeting.segments = [
            Segment(source: "system", speaker: "system:speaker-1", start: 385, end: 387, text: "Probably a couple cutscenes"),
            Segment(source: "system", speaker: "system:speaker-1", start: 412, end: 413, text: "I need my compass"),
            Segment(source: "system", speaker: "system:speaker-1", start: 423, end: 424, text: "unless I get more food"),
            Segment(source: "system", speaker: "system:speaker-1", start: 429, end: 431, text: "a more billion cutscenes left"),
            Segment(source: "system", speaker: "system:speaker-2", start: 460, end: 465, text: "Hokkaido ones require reservations and that could trip them out")]
        let plan = try NotePlanner.finalPlan(meeting)
        let bad = NoteDraft(plan: plan, output: "* **Count:** 1 billion left.\n* **Supplies:** Food is conditional on finding a compass.")
        let safe = NoteEnhancer.extractive(bad, meeting: meeting)
        let result = NoteEnhancement.apply(safe.output, plan: safe.plan, to: meeting.notes!)
        XCTAssertTrue(result.notes[0].enhanced!.contains("Probably a couple cutscenes"))
        XCTAssertFalse(result.notes[0].enhanced!.contains("billion"))
        XCTAssertTrue(result.notes[1].enhanced!.contains("I need my compass"))
        XCTAssertTrue(result.notes[1].enhanced!.contains("unless I get more food"))
        XCTAssertFalse(result.notes[1].enhanced!.contains("conditional"))
        XCTAssertNil(result.notes[2].enhanced)
        XCTAssertTrue(result.missed!.contains { $0.text.contains("Hokkaido") })
        XCTAssertEqual(safe.model, "Transcript excerpts · local fallback")
    }
    func testFinalTopicsRecoverOmittedCitationsButRejectInventedReferences() throws {
        var meeting = Meeting(title: "Challenge")
        meeting.segments = [Segment(source: "system", speaker: "system:speaker-1", start: 470, end: 500,
            text: "Complete the Japan food hunt after disembarking at any station without using your phone. One team member must consume six of eight items within one hour.")]
        let plan = try NotePlanner.finalPlan(meeting)
        let enhancer = NoteEnhancer()
        let result = enhancer.groundedTopics("* **Japan food hunt:** Consume six of eight items within one hour without using a phone.", excerpts: plan.uncovered)
        XCTAssertEqual(result.count, 1); XCTAssertEqual(result.first?.refs, ["U1"])
        XCTAssertTrue(enhancer.groundedTopics("* **Japan food hunt:** Consume six items. (U999)", excerpts: plan.uncovered).isEmpty)
    }
    func testMissingModelBulletDoesNotReportZeroMatches() async throws {
        let (model, root, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        model.batchTranscriber = BatchFixture()
        let scheduler = NoteEnhancementScheduler(); scheduler.enhancer = DroppedLineFixture()
        await scheduler.finish(model.meeting!.id, model: model)
        let note = try XCTUnwrap(model.meeting?.notes?.first)
        XCTAssertNil(note.enhanced)
        XCTAssertEqual(note.excerptRefs?.count, 1)
        XCTAssertEqual(note.trace?.steps.first?.detail, "1 excerpts")
        XCTAssertEqual(note.trace?.steps.dropFirst().first?.title, "No usable AI line")
    }
    func fixture() throws -> (AppModel, URL, Segment) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(store: MeetingStore(root: root))
        var meeting = Meeting(title: "Travel")
        meeting.status = "complete"; meeting.endedAt = Date(); meeting.sourceOffsets = ["system": 100]
        let original = Segment(source: "system", speaker: "system:speaker-3", start: 102, end: 104, text: "hokaido ones")
        meeting.segments = [original]; meeting.notes = [Note(text: "reservations", createdAt: 103)]
        model.meeting = meeting; model.phase = "ready"
        try model.store.save(meeting)
        try Data([0]).write(to: model.store.directory(meeting.id).appendingPathComponent("system.wav"))
        try Data([0]).write(to: model.store.directory(meeting.id).appendingPathComponent("microphone.wav"))
        return (model, root, original)
    }
    func testFinalPassUsesBatchTextPreservesAnchorAndOnlyRunsOnce() async throws {
        let (model, root, original) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let batch = BatchFixture(), notes = PolishedNotesFixture(), scheduler = NoteEnhancementScheduler()
        model.batchTranscriber = batch; scheduler.enhancer = notes
        let id = model.meeting!.id
        let succeeded = await scheduler.finish(id, model: model)
        XCTAssertTrue(succeeded)
        let received = await notes.text
        XCTAssertEqual(received, "Hokkaido reservations.")
        XCTAssertEqual(model.meeting?.segments.first?.id, original.id)
        XCTAssertEqual(model.meeting?.segments.first?.speaker, original.speaker)
        XCTAssertNotNil(model.meeting?.transcriptPolishedForEnd)
        try await model.polishTranscript(id)
        let calls = await batch.calls; XCTAssertEqual(calls, 1)
    }
    func testIncrementalWorkCannotRaceTheBatchFinalPass() async throws {
        let (model, root, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let batch = BatchFixture(suspend: true), notes = PolishedNotesFixture(), scheduler = NoteEnhancementScheduler()
        scheduler.delay = 1_000_000; scheduler.minimumInterval = 0
        scheduler.enhancer = notes; model.batchTranscriber = batch
        let id = model.meeting!.id
        let task = Task { await scheduler.finish(id, model: model) }
        while !(await batch.waiting) { await Task.yield() }
        XCTAssertEqual(model.message, "Polishing the transcript…")
        scheduler.schedule(id, model: model)
        try await Task.sleep(nanoseconds: 20_000_000)
        let before = await notes.text; XCTAssertEqual(before, "")
        await batch.release()
        let complete = await task.value; XCTAssertTrue(complete)
        let after = await notes.text; XCTAssertEqual(after, "Hokkaido reservations.")
    }
    func testResumeWhileBatchRunsDoesNotOverwriteNewCapture() async throws {
        let (model, root, original) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let batch = BatchFixture(suspend: true); model.batchTranscriber = batch
        let task = Task { try await model.polishTranscript(model.meeting!.id) }
        while !(await batch.waiting) { await Task.yield() }
        try model.meeting!.resume()
        await batch.release(); _ = try? await task.value
        XCTAssertEqual(model.meeting?.segments.first?.text, original.text)
        XCTAssertNil(model.meeting?.transcriptPolishedForEnd)
        XCTAssertNil(model.meeting?.endedAt)
    }
    func testPurgeWhileBatchRunsCannotResurrectText() async throws {
        let (model, root, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let batch = BatchFixture(suspend: true); model.batchTranscriber = batch
        let task = Task { try await model.polishTranscript(model.meeting!.id) }
        while !(await batch.waiting) { await Task.yield() }
        model.meeting?.retention = "purged"; model.meeting?.segments = []
        try FileManager.default.removeItem(at: root)
        await batch.release(); _ = try? await task.value
        XCTAssertEqual(model.meeting?.segments.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
