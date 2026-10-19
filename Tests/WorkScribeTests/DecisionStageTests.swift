import XCTest
import Foundation
@testable import WorkScribe
import WorkScribeCore

final class DecisionStageTests: XCTestCase {
    struct TimedOnlyHead: DecisionModel {
        let relevanceThreshold = 0.5, answerabilityThreshold = 0.5
        enum Failure: Error { case untimedHeadCall }
        func relevance(jot: Note, candidates: [TranscriptChunk]) throws -> [Double] {
            guard candidates.isEmpty else { throw Failure.untimedHeadCall }; return []
        }
        func updateRelevance(jot: Note, candidates: [TranscriptChunk]) throws -> [Double] { throw Failure.untimedHeadCall }
        func answerability(jot: Note, evidence: [TranscriptChunk]) throws -> Double { throw Failure.untimedHeadCall }
    }
    func testVaultEvidenceNeverUsesTheTimedUpdateHead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try SearchIndex(url: root.appendingPathComponent("index.sqlite"))
        let source = SourceID(.vault, "fixture")
        _ = try index.apply(SourceRevision(source: source, passages: [Passage(text: "Archive retention lasts fourteen days.", source: source, anchor: "one")]))
        try await index.embedMissing(source, using: FixtureEmbedder())
        var meeting = Meeting(title: "Vault"); meeting.status = "complete"
        meeting.notes = [Note(text: "archive retention", createdAt: nil)]
        let engine = Enrich(decisionModel: TimedOnlyHead(), embeddingSource: { FixtureEmbedder() }, indexSource: { index })
        let plan = try await engine.selection(meeting, incremental: true)
        XCTAssertEqual(plan.targets.count, 1); XCTAssertTrue(plan.targets[0].backgroundOnly)
        XCTAssertFalse(plan.targets[0].refs.isEmpty)
    }
    struct Gate: DecisionModel {
        let relevanceThreshold = 0.1, answerabilityThreshold = 0.5
        func relevance(jot: Note, candidates: [TranscriptChunk]) throws -> [Double] { candidates.map { _ in 0.9 } }
        func answerability(jot: Note, evidence: [TranscriptChunk]) throws -> Double { 0.01 }
    }
    func testAnswerabilityGateSuppressesGeneratorEvidence() async throws {
        var meeting = Meeting(title: "decision-test")
        meeting.notes = [Note(text: "price", createdAt: 5)]
        meeting.segments = [Segment(source: "system", speaker: "speaker1", start: 0, end: 10, text: "The price is ten dollars per seat each month.")]
        let baseline = try await Enrich(decisionModel: FixtureDecision(), embeddingSource: { FixtureEmbedder() }).selection(meeting, incremental: false)
        XCTAssertFalse(baseline.targets[0].refs.isEmpty)
        let gated = try await Enrich(decisionModel: Gate(), embeddingSource: { FixtureEmbedder() }).selection(meeting, incremental: false)
        XCTAssertTrue(gated.targets[0].refs.isEmpty)
        XCTAssertEqual(gated.targets[0].note.text, "price")
    }
    struct TopicHead: DecisionModel {
        let relevanceThreshold = 0.042, answerabilityThreshold = 0.5
        func relevance(jot: Note, candidates: [TranscriptChunk]) throws -> [Double] {
            candidates.map { _ in 0.9 }
        }
        func updateRelevance(jot: Note, candidates: [TranscriptChunk]) throws -> [Double] {
            candidates.map { $0.text.contains("unrelated") ? 0.1 : 0.9 }
        }
        func answerability(jot: Note, evidence: [TranscriptChunk]) throws -> Double { 1 }
    }
    func testNeighborOnlyContextCannotQueueAnAnsweredLine() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Meeting(title: "Price"); meeting.status = "recording"
        meeting.segments = [Segment(source: "s", speaker: "a", start: 0, end: 5, text: "Price is ten dollars."),
                            Segment(source: "s", speaker: "a", start: 6, end: 7, text: "An unrelated topic.")]
        var note = Note(text: "price", createdAt: 5)
        note.line.text = "Price is ten dollars."; note.line.queryText = note.text
        meeting.notes = [note]
        let index = try SearchIndex(url: root.appendingPathComponent("index.sqlite"))
        let source = SourceID(.meeting, meeting.id)
        _ = try index.apply(MeetingSource.revision(meeting))
        try await index.embedMissing(source, using: FixtureEmbedder())
        let chunks = try index.sourceChunks(source)
        meeting.notes![0].line.evidence = [chunks[0].id]
        var watch = Watch(); watch.text = note.matchingText; watch.seenThrough = chunks[0].seq
        try index.saveWatch(watch, source: source, query: note.id)
        let enhancer = Enrich(decisionModel: TopicHead(), embeddingSource: { FixtureEmbedder() }, indexSource: { index })
        let result = try await enhancer.selection(meeting, incremental: true)
        XCTAssertTrue(result.targets.isEmpty)
    }

    struct PlainBulletModel: TextModel {
        let displayName = "plain fixture", backend = TextBackend.llama, isAvailable = true
        func generate(_ request: TextRequest) async throws -> TextGeneration {
            XCTAssertFalse(request.instruction.hasPrefix(NotePrompt.topicsHead))
            return TextGeneration(text: "* The price is ten dollars per seat each month.", stats: TextStats())
        }
        func stream(_ request: TextRequest) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
        func prewarm(_ request: TextRequest?) async {}
        func release() async {}
    }
    func testSettleDoesNotStartOptionalSynthesis() async throws {
        var meeting = Meeting(title: "plain bullet"); meeting.status = "recording"
        meeting.notes = [Note(text: "price?", createdAt: 5)]
        meeting.segments = [Segment(source: "system", speaker: "A", start: 0, end: 5, text: "The price is ten dollars per seat each month.")]
        let enhancer = Enrich(textModel: PlainBulletModel(), decisionModel: FixtureDecision(), embeddingSource: { FixtureEmbedder() })
        let liveValue = try await enhancer.enhance(meeting, incremental: true)
        let live = try XCTUnwrap(liveValue)
        XCTAssertNotNil(live.outcomes[meeting.notes![0].id])
        meeting.status = "complete"
        let settledValue = try await enhancer.enhance(meeting, incremental: false)
        let settled = try XCTUnwrap(settledValue)
        XCTAssertNotNil(settled.outcomes[meeting.notes![0].id])
    }

    struct TextOnlyHead: DecisionModel {
        let relevanceThreshold = 0.0, answerabilityThreshold = 0.5
        func relevance(jot: Note, candidates: [TranscriptChunk]) throws -> [Double] {
            guard !jot.isImage && !jot.matchingText.isEmpty else { throw CaptureError.message("Image-only jot entered the text head") }
            return candidates.map { _ in 0.9 }
        }
        func answerability(jot: Note, evidence: [TranscriptChunk]) throws -> Double { 1 }
    }
    func testImageOnlyJotBypassesTextHeadBesideATextJot() async throws {
        var meeting = Meeting(title: "Mixed evidence")
        var image = NoteImage(target: "chart.png"); image.caption = "The chart shows the approved budget."
        var imageNote = Note(text: "", createdAt: 5); imageNote.images = [image]
        let textNote = Note(text: "budget?", createdAt: 5)
        meeting.notes = [imageNote, textNote]
        meeting.segments = [Segment(source: "s", speaker: "A", start: 0, end: 5, text: "The budget is approved for next week.")]
        let plan = try await Enrich(decisionModel: TextOnlyHead(), embeddingSource: { FixtureEmbedder() }).selection(meeting, incremental: false)
        XCTAssertEqual(plan.targets.count, 2)
        XCTAssertTrue(plan.targets.first { $0.note.id == imageNote.id }!.refs.isEmpty)
        XCTAssertFalse(plan.targets.first { $0.note.id == textNote.id }!.refs.isEmpty)
    }

}
