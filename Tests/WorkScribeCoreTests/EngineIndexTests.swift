import XCTest
@testable import WorkScribeCore

final class EngineIndexTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private let vector = Array(repeating: Float(1 / 16.0), count: 256)

    func testSharedChunkerPreservesPassageBoundariesAndContext() {
        let words = Array(repeating: "word", count: 45).joined(separator: " ") + ". "
        let a = Passage(text: words + words, source: SourceID(.meeting, "m"), anchor: "s")
        let b = Passage(text: a.text, source: SourceID(.vault, "v"), anchor: "h#0", context: "Title > Heading")
        XCTAssertEqual(Chunker.chunks(a).map(\.text), Chunker.chunks(b).map(\.text))
        XCTAssertEqual(Chunker.chunks(a).count, 2)
        XCTAssertTrue(Chunker.chunks(b).allSatisfy { $0.embeddedText.hasPrefix("Title > Heading\n\n") })
        XCTAssertEqual(Chunker.chunks(a).map(\.id), Chunker.chunks(a).map(\.id))
        XCTAssertNotEqual(Chunker.chunks(a).first?.id, Chunker.chunks(b).first?.id)
        let short = Passage(text: "One. Two.", source: a.source, anchor: "other")
        XCTAssertEqual(Chunker.chunks(short).count, 1)
    }

    func testHardSplitAndShortTailJoinLoseNoWords() {
        for count in [59, 60, 61, 74, 75, 119, 120, 121, 137] {
            let words = (0..<count).map { "word\($0)" }
            let p = Passage(text: words.joined(separator: " "), anchor: "p")
            let chunks = Chunker.chunks(p)
            XCTAssertEqual(chunks.flatMap { ($0.text ?? "").split(separator: " ").map(String.init) }, words)
            XCTAssertTrue(chunks.allSatisfy { ($0.text ?? "").split(separator: " ").count <= 74 })
        }
    }

    func testRevisionDiffReusesVectorsAndSequenceButNotAcrossSources() throws {
        let index = try SearchIndex(url: root().appendingPathComponent("index.sqlite"))
        try index.adopt(modelID: "test")
        let source = SourceID(.meeting, "m")
        var p = Passage(text: "Budget approved.", source: source, anchor: "s1", speaker: "Speaker 1")
        let first = try index.apply(SourceRevision(source: source, revision: 1, passages: [p]))
        let id = try XCTUnwrap(first.added.first?.id)
        try index.setVectors([id: vector], model: "test")
        p.speaker = "Alice"
        let renamed = try index.apply(SourceRevision(source: source, revision: 2, passages: [p]))
        XCTAssertTrue(renamed.added.isEmpty); XCTAssertTrue(renamed.removed.isEmpty)
        XCTAssertEqual(try index.sourceChunks(source).first?.seq, first.added.first?.seq)
        XCTAssertEqual(try index.sourceChunks(source).first?.speakers, ["Alice"])
        p.anchor = "s2"
        let moved = try index.apply(SourceRevision(source: source, revision: 3, passages: [p]))
        XCTAssertEqual(moved.removed, [id]); XCTAssertNotNil(moved.added.first?.vector)
        XCTAssertGreaterThan(moved.added[0].seq, first.added[0].seq)
        let other = SourceID(.vault, "other"); p.source = other
        let independent = try index.apply(SourceRevision(source: other, passages: [p]))
        XCTAssertNil(independent.added.first?.vector)
        XCTAssertThrowsError(try index.apply(SourceRevision(source: source, passages: [p])))
        p.source = source; p.text = "Obsolete revision"
        XCTAssertTrue(try index.apply(SourceRevision(source: source, revision: 1, passages: [p])).added.isEmpty)
    }

    func testAttributeAndVisualVectorUpdatesRetainIdentity() throws {
        let index = try SearchIndex(url: root().appendingPathComponent("index.sqlite"))
        try index.adopt(modelID: "test")
        let source = SourceID(.screen, "screen")
        var passage = Passage(text: "Scene", source: source, anchor: "frame", kind: .screen, modality: .image,
                              thumbnail: "old.jpg", window: "Old", vector: vector)
        _ = try index.apply(SourceRevision(source: source, passages: [passage]))
        let before = try XCTUnwrap(index.sourceChunks(source).first)
        passage.thumbnail = "new.jpg"; passage.window = "New"; passage.page = 2; passage.track = "screen"
        passage.vector = [1] + Array(repeating: 0, count: 255)
        _ = try index.apply(SourceRevision(source: source, passages: [passage]))
        let after = try XCTUnwrap(index.sourceChunks(source).first)
        XCTAssertEqual(after.id, before.id); XCTAssertEqual(after.seq, before.seq)
        XCTAssertEqual(after.thumbnail, "new.jpg"); XCTAssertEqual(after.window, "New")
        XCTAssertEqual(after.page, 2); XCTAssertEqual(after.track, "screen")
        XCTAssertEqual(after.vector?.first, 1)
    }

    func testUnchangedRevisionDoesNotGrowTheVectorJournal() throws {
        let index = try SearchIndex(url: root().appendingPathComponent("index.sqlite"))
        try index.adopt(modelID: "test")
        let source = SourceID(.meeting, "m")
        let revision = SourceRevision(source: source, passages: [Passage(text: "Final words", source: source, anchor: "a", start: 1, end: 3)],
                                      title: "Meeting", startedAt: Date(timeIntervalSince1970: 100))
        let first = try index.apply(revision)
        try index.setVectors([first.added[0].id: vector], model: "test")
        let before = try index.db.scalar("SELECT COUNT(*) FROM vector_changes")
        for _ in 0..<20 { _ = try index.apply(revision) }
        XCTAssertEqual(try index.db.scalar("SELECT COUNT(*) FROM vector_changes"), before)
    }

    func testKeywordsPrecedeVectorsAndCandidatesObeyScope() throws {
        let index = try SearchIndex(url: root().appendingPathComponent("index.sqlite"))
        try index.adopt(modelID: "test")
        for (kind, ref) in [(SourceID.Kind.meeting, "m"), (.vault, "v")] {
            let source = SourceID(kind, ref)
            let delta = try index.apply(SourceRevision(source: source, passages: [Passage(text: "Shared canary", source: source, anchor: "a", start: 10, end: 12)]))
            XCTAssertFalse(try index.search(SearchRequest("canary", sourceRef: ref)).hits.isEmpty)
            let query = QueryVector(text: "canary", vector: vector, model: "test")
            XCTAssertTrue(try index.candidates(query, scope: .linked([source]), limit: 10).isEmpty)
            try index.setVectors([delta.added[0].id: vector], model: "test")
        }
        let query = QueryVector(text: "canary", vector: vector, model: "test")
        XCTAssertEqual(try index.candidates(query, scope: .meeting("m", 9...11), limit: 10).count, 1)
        XCTAssertTrue(try index.candidates(query, scope: .meeting("m", 13...15), limit: 10).isEmpty)
        XCTAssertEqual(try index.candidates(query, scope: .vault(excluding: []), limit: 10).map(\.source.ref), ["v"])
    }

    func testPurgeErasesCanaryAndFencesLateWritesAcrossReopen() throws {
        let root = try root(), path = root.appendingPathComponent("index.sqlite")
        let source = SourceID(.meeting, "private-meeting")
        let canary = "uniqueprivatecanaryxkz"
        let revision = SourceRevision(source: source, passages: [Passage(text: canary, source: source, anchor: "s1")])
        let index = try SearchIndex(url: path)
        try index.adopt(modelID: "test")
        let delta = try index.apply(revision)
        try index.setVectors([delta.added[0].id: vector], model: "test")
        XCTAssertEqual(try index.vectorStats().count, 1)
        var watch = Watch(); watch.text = canary; watch.seenThrough = 9
        _ = watch.identifier(delta.added[0].id)
        try index.saveWatch(watch, source: source, query: "q")
        XCTAssertEqual(try index.watch(source: source, query: "q"), watch)
        try index.purge(source)
        try index.saveWatch(watch, source: source, query: "q")
        XCTAssertEqual(try index.watch(source: source, query: "q"), Watch())
        try index.setVectors([delta.added[0].id: vector], model: "test")
        XCTAssertTrue(try index.apply(revision).added.isEmpty)
        XCTAssertEqual(try index.counts().chunks, 0)
        XCTAssertEqual(try index.vectorStats().count, 0)
        let reopened = try SearchIndex(url: path)
        XCTAssertTrue(try reopened.apply(revision).added.isEmpty)
        for case let file as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)! {
            if let data = try? Data(contentsOf: file) { XCTAssertNil(data.range(of: Data(canary.utf8)), file.path) }
        }
    }

    func testPartialSpeechIsExcludedAndCorrectionChangesIdentity() {
        var meeting = Meeting(title: "Meeting"); meeting.status = "recording"
        meeting.setPartial("Never indexed", source: "system", speaker: "system:1", span: (1, 5))
        XCTAssertTrue(Chunker.chunks(MeetingSource.revision(meeting)).isEmpty)
        meeting.segments = [Segment(source: "system", speaker: "system:1", start: 1, end: 5, text: "Final words")]
        let first = Chunker.chunks(MeetingSource.revision(meeting))
        meeting.segments[0].text = "Corrected final words"
        XCTAssertNotEqual(first[0].id, Chunker.chunks(MeetingSource.revision(meeting))[0].id)
    }
}

extension EngineIndexTests {
    func testMeasureIndexFootprintAndCandidateLatency() throws {
        let root = try root(), path = root.appendingPathComponent("index.sqlite")
        let index = try SearchIndex(url: path)
        try index.adopt(modelID: "measurement")
        let meeting = SourceID(.meeting, "hour")
        let vault = SourceID(.vault, "library")
        let vector = (0..<768).map { Float(($0 % 19) + 1) }
        func populate(_ source: SourceID, count: Int) throws {
            var passages: [Passage] = []
            for i in 0..<count {
                let start: Double? = source == meeting ? Double(i * 5) : nil
                let end: Double? = source == meeting ? Double(i * 5 + 4) : nil
                passages.append(Passage(text: "Project budget decision number \(i) remains under review with the design team today.",
                                        source: source, anchor: String(i), start: start, end: end))
            }
            let delta = try index.apply(SourceRevision(source: source, passages: passages))
            try index.setVectors(Dictionary(uniqueKeysWithValues: delta.added.map { ($0.id, vector) }), model: "measurement")
        }
        try populate(meeting, count: 700)
        _ = try index.vectorStats()
        try index.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        let hourBytes = (try FileManager.default.attributesOfItem(atPath: path.path)[.size] as! NSNumber).intValue
        let hourAccelerator = try index.vectorStats().mappedBytes
        try populate(vault, count: 10_000)
        _ = try index.vectorStats()
        try index.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        let combinedBytes = (try FileManager.default.attributesOfItem(atPath: path.path)[.size] as! NSNumber).intValue
        let query = QueryVector(text: "budget decision", vector: VectorMath.normalized(vector)!, model: "measurement")
        var timings: [Double] = [], findTimings: [Double] = [], completeTimings: [Double] = []
        let loaded = try index.sourceChunks(meeting)
        let queryVectors = IndexVectors(modelID: "embeddinggemma-2-coreml/text@70fcf18f+audio@c0fefd0a+vision70@3f978ddf/768", queries: ["budget decision": query.vector], chunks: loaded)
        let head = try EmbeddingDecisionModel.bundled(cache: queryVectors, chunks: loaded.map(\.transcript))
        let note = Note(text: "budget decision", createdAt: 3450)
        var watch = Watch()
        for _ in 0..<30 {
            let began = ContinuousClock.now
            let result = try Find().run(note: note, meeting: loaded, closed: false, decision: head, watch: &watch) { _ in XCTFail("Successful moment searched vault"); return [] }
            XCTAssertEqual(result.rung, .moment)
            let took = ContinuousClock.now - began
            findTimings.append(Double(took.components.seconds) * 1000 + Double(took.components.attoseconds) / 1e15)
        }
        findTimings.sort()
        for _ in 0..<30 {
            let began = ContinuousClock.now
            let rows = try index.sourceChunks(meeting)
            let view = IndexVectors(modelID: queryVectors.modelID, queries: ["budget decision": query.vector], chunks: rows)
            let decision = try EmbeddingDecisionModel.bundled(cache: view, chunks: rows.map(\.transcript))
            _ = try Find().run(note: note, meeting: rows, closed: false, decision: decision, watch: &watch) { _ in [] }
            let took = ContinuousClock.now - began
            completeTimings.append(Double(took.components.seconds) * 1000 + Double(took.components.attoseconds) / 1e15)
        }
        completeTimings.sort()
        for _ in 0..<30 {
            let start = ContinuousClock.now
            XCTAssertEqual(try index.candidates(query, scope: .meeting("hour", nil), limit: 48).count, 48)
            XCTAssertEqual(try index.candidates(query, scope: .vault(excluding: []), limit: 48).count, 48)
            let elapsed = ContinuousClock.now - start
            timings.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        timings.sort()
        let start = ContinuousClock.now
        try index.purge(meeting)
        let elapsed = ContinuousClock.now - start
        let remaining = try index.sourceChunks(meeting).count
        let record: [String: Any] = ["meeting_chunks": 700, "vault_chunks": 10000,
            "meeting_sqlite_bytes": hourBytes, "meeting_accelerator_bytes": hourAccelerator,
            "vault_sqlite_bytes_per_chunk": Double(combinedBytes - hourBytes) / 10000,
            "find_decide_with_index_p50_ms": completeTimings[15], "find_decide_with_index_p95_ms": completeTimings[28],
            "find_decide_moment_p50_ms": findTimings[15], "find_decide_moment_p95_ms": findTimings[28],
            "find_meeting_plus_vault_p50_ms": timings[15], "find_meeting_plus_vault_p95_ms": timings[28],
            "purge_ms": Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15,
            "meeting_rows_after_purge": remaining]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        print("STAGE3_INDEX_MEASUREMENT " + String(decoding: data, as: UTF8.self))
        XCTAssertEqual(remaining, 0)
    }
}

private struct IndexOrderExtractor: FileExtracting {
    func passages(of url: URL, kind: ChunkKind) async throws -> (title: String?, passages: [Passage]) {
        (nil, [Passage(text: "published pixels")])
    }
    func audioWindows(of url: URL, _ body: (AudioWindow) async throws -> Void) async throws {}
}
private struct IndexOrderEmbedder: Embedder {
    let index: SearchIndex
    let modelID = "image-order", dimension = 256, supportsImages = true, supportsAudio = false
    func text(_ value: String, role: TextRole) async throws -> [Float] { Array(repeating: 1 / 16, count: 256) }
    func image(_ url: URL) async throws -> [Float] {
        guard !(try index.search(SearchRequest("published pixels", sourceRef: url.path))).hits.isEmpty else {
            throw Database.Failure(message: "Image inference began before OCR was indexed")
        }
        return [1] + Array(repeating: 0, count: 255)
    }
    func audio(_ pcm16k: [Float]) async throws -> [Float] { throw EmbedderError.audioUnsupported }
}
extension EngineIndexTests {
    func testOCRIsSearchableBeforeImageInferenceAndImageChangesReplaceIdentity() async throws {
        let root = try root(), file = root.appendingPathComponent("picture.png")
        try Data([1]).write(to: file)
        let index = try SearchIndex(url: root.appendingPathComponent("index.sqlite"))
        let indexer = FolderIndexer(index: index, embedder: IndexOrderEmbedder(index: index), extractor: IndexOrderExtractor())
        _ = try await indexer.index(file, kind: .image, root: root.path)
        let source = SourceID(.folder, file.path)
        let first = try XCTUnwrap(index.sourceChunks(source).first { $0.modality == .image })
        XCTAssertNotNil(first.vector)
        try Data([2,3]).write(to: file)
        _ = try await indexer.index(file, kind: .image, root: root.path)
        let second = try XCTUnwrap(index.sourceChunks(source).first { $0.modality == .image })
        XCTAssertNotNil(second.vector); XCTAssertNotEqual(first.id, second.id)
    }
}
