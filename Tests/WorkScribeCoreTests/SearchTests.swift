import XCTest
@testable import WorkScribeCore

/// A deterministic stand-in for EmbeddingGemma: words map to concepts, so "ad spend" and "advertising budget" land
/// close together without sharing a word, and unrelated text lands far away.
final class FakeEmbedder: Embedder, @unchecked Sendable {
    let modelID: String
    let dimension = 32
    let supportsAudio = true
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    init(modelID: String = "fake@1") { self.modelID = modelID }

    static let concepts: [String: Int] = [
        "budget": 0, "spend": 0, "spending": 0, "advertising": 0, "ad": 0, "ads": 0, "marketing": 0, "cost": 0, "costs": 0,
        "hire": 1, "hiring": 1, "designer": 1, "candidate": 1, "recruit": 1, "interview": 1,
        "outage": 2, "down": 2, "database": 2, "incident": 2, "postmortem": 2, "checkout": 2,
        "invoice": 3, "contract": 3, "legal": 3, "signed": 3,
        "hum": 4, "beep": 4,
    ]

    func vector(_ text: String) -> [Float] {
        var v = [Float](repeating: 0, count: dimension)
        for word in text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted) where !word.isEmpty {
            if let concept = Self.concepts[word] { v[concept] += 3 } else {
                var hash = StableHash(); hash.add(word)
                v[5 + Int(UInt64(hash.hex, radix: 16)! % UInt64(dimension - 5))] += 0.3
            }
        }
        v[dimension - 1] += 0.05
        return v
    }
    func text(_ value: String, role: TextRole) async throws -> [Float] {
        lock.withLock { _calls += 1 }
        return vector(value)
    }
    func audio(_ pcm16k: [Float]) async throws -> [Float] {
        lock.withLock { _calls += 1 }
        return vector("hum beep")
    }
}

final class SearchTests: XCTestCase {
    var folder: URL!
    var store: MeetingStore!
    var index: SearchIndex!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ws-search-" + UUID().uuidString)
        store = MeetingStore(root: folder.appendingPathComponent("Meetings"))
        index = try SearchIndex(url: folder.appendingPathComponent("Index/index.sqlite"))
    }
    override func tearDownWithError() throws { index = nil; try? FileManager.default.removeItem(at: folder) }

    func segment(_ speaker: String, _ start: Double, _ end: Double, _ text: String) -> Segment {
        Segment(source: speaker.components(separatedBy: ":").first ?? "microphone", speaker: speaker, start: start, end: end, text: text)
    }

    /// Three topics, ~20 s each, plus filler between them.
    func sampleMeeting(title: String = "Weekly sync") -> Meeting {
        var meeting = Meeting(title: title)
        meeting.status = "complete"
        meeting.segments = [
            segment("microphone:speaker-1", 0, 8, "Let us start with the quarter."),
            segment("system:speaker-1", 8, 20, "We should cut the advertising budget by a third."),
            segment("microphone:speaker-1", 20, 30, "Agreed, marketing spend is too high."),
            segment("system:speaker-2", 30, 45, "Next, we are hiring a product designer this month."),
            segment("microphone:speaker-1", 45, 58, "The candidate wants a remote role."),
            segment("system:speaker-1", 58, 75, "Then the database outage last night took checkout down."),
            segment("system:speaker-2", 75, 90, "I will write the incident postmortem tomorrow."),
            segment("microphone:speaker-1", 90, 105, "Send me invoice INV-4821 when the contract is signed."),
        ]
        return meeting
    }

    // MARK: Schema and migration

    func testFreshSchemaAndReopen() throws {
        XCTAssertEqual(index.userVersion, SearchIndex.schemaVersion)
        var tables: Set<String> = []
        try index.db.query("SELECT name FROM sqlite_master WHERE type IN ('table')") { tables.insert($0.text(0) ?? "") }
        XCTAssertTrue(tables.isSuperset(of: ["meta", "folders", "sources", "chunks", "fts"]))
        try index.replace(kind: .file, ref: "/tmp/a.txt", title: "a.txt", fingerprint: "f", modelID: nil,
                          chunks: [Chunk(kind: .document, modality: .text, text: "hello world")])
        let url = index.url
        index = nil
        let reopened = try SearchIndex(url: url)
        XCTAssertEqual(reopened.userVersion, SearchIndex.schemaVersion)
        XCTAssertEqual(try reopened.counts(), .init(sources: 1, chunks: 1, vectors: 0))
        index = reopened
    }

    func testNewerSchemaIsRefused() throws {
        try index.db.execute("PRAGMA user_version = 99")
        XCTAssertThrowsError(try SearchIndex(url: index.url))
    }

    func testModelChangeDropsVectorsAndForcesReembed() async throws {
        let first = FakeEmbedder(modelID: "fake@1")
        try store.save(sampleMeeting())
        _ = try await MeetingIndexer(index: index, embedder: first).sync(store: store)
        let vectors = try index.counts().vectors
        XCTAssertGreaterThan(vectors, 0)
        XCTAssertEqual(index.vectorModel, "fake@1")

        let second = FakeEmbedder(modelID: "fake@2")
        let report = try await MeetingIndexer(index: index, embedder: second).sync(store: store)
        XCTAssertEqual(report.indexed, 1)
        XCTAssertEqual(index.vectorModel, "fake@2")
        XCTAssertEqual(try index.counts().vectors, vectors)
        XCTAssertGreaterThan(second.calls, 0)
    }

    // MARK: Chunking

    func testMeetingChunksKeepSpeakersTimesAndEverySegment() {
        var meeting = Meeting(title: "Long")
        meeting.segments = (0..<30).map { i in
            segment(i % 3 == 0 ? "system:speaker-2" : "microphone:speaker-1", Double(i) * 5, Double(i) * 5 + 4.5, "Sentence number \(i) here.")
        }
        meeting.speakerAssignments = ["system:speaker-2": SpeakerAssignment(name: "Priya")]
        let chunks = Chunker.chunks(MeetingSource.revision(meeting))
        XCTAssertGreaterThan(chunks.count, 2)
        for chunk in chunks {
            let span = chunk.end! - chunk.start!
            XCTAssertEqual(span, 4.5)
            XCTAssertEqual(chunk.anchorSegment, chunk.segmentIDs.first)
        }
        XCTAssertEqual(chunks.flatMap(\.segmentIDs), meeting.orderedSegments.map(\.id))
        XCTAssertEqual(chunks[0].speakers, ["Priya"])
        XCTAssertEqual(chunks[0].speakerKeys, ["system:speaker-2"])
        XCTAssertEqual(chunks[0].track, "system")
        XCTAssertFalse(chunks[0].text!.contains("Priya"))   // names stay out of the embedded text
    }

    func testMonologueIsSplitWithInterpolatedTimes() {
        var meeting = Meeting(title: "Talk")
        let words = (0..<400).map { "word\($0)" }.joined(separator: " ")
        let long = segment("microphone:speaker-1", 10, 130, words)
        meeting.segments = [long]
        let chunks = Chunker.chunks(MeetingSource.revision(meeting))
        XCTAssertGreaterThanOrEqual(chunks.count, 3)
        XCTAssertEqual(chunks.first?.start ?? -1, 10, accuracy: 0.01)
        XCTAssertEqual(chunks.last?.end ?? -1, 130, accuracy: 0.01)
        XCTAssertTrue(chunks.allSatisfy { $0.anchorSegment == long.id })
    }

    // MARK: Ranking

    func testMeaningFindsTheMomentWithoutSharedWords() async throws {
        let embedder = FakeEmbedder()
        let meeting = sampleMeeting()
        try store.save(meeting)
        _ = try await MeetingIndexer(index: index, embedder: embedder).sync(store: store)
        let query = "ad cost"   // no word in common, and too short for a prefix match
        let results = try index.search(SearchRequest(query, perSource: nil), queryVector: embedder.vector(query), queryModelID: embedder.modelID)
        XCTAssertTrue(results.semantic)
        let top = try XCTUnwrap(results.hits.first)
        XCTAssertEqual(top.ref, meeting.id)
        XCTAssertTrue(top.text!.contains("advertising budget") || top.text!.contains("marketing spend"))
        XCTAssertEqual(top.match, .meaning)
        XCTAssertEqual(top.link, .meeting(id: meeting.id, seconds: top.start, segment: top.anchorSegment))
    }

    func testWordsWinForCodesAndFusionMarksBoth() async throws {
        let embedder = FakeEmbedder()
        let meeting = sampleMeeting()
        try store.save(meeting)
        _ = try await MeetingIndexer(index: index, embedder: embedder).sync(store: store)
        let lookup = "INV-4821"
        let results = try index.search(SearchRequest(lookup), queryVector: embedder.vector(lookup), queryModelID: embedder.modelID)
        let top = try XCTUnwrap(results.hits.first)
        XCTAssertTrue(top.text!.contains("INV-4821"))
        XCTAssertNotEqual(top.match, .meaning)
        XCTAssertTrue(top.snippet?.contains("«") ?? false)

        let both = "database outage"
        let fused = try index.search(SearchRequest(both), queryVector: embedder.vector(both), queryModelID: embedder.modelID)
        XCTAssertEqual(fused.hits.first?.match, .both)
        XCTAssertTrue(fused.hits.first?.text?.contains("outage") ?? false)
    }

    func testKeywordOnlyWithoutVectorsOrWithAnotherModel() async throws {
        try store.save(sampleMeeting())
        _ = try await MeetingIndexer(index: index, embedder: nil).sync(store: store)
        XCTAssertEqual(try index.counts().vectors, 0)
        let words = try index.search(SearchRequest("designer"))
        XCTAssertFalse(words.semantic)
        XCTAssertTrue(words.hits.first?.text?.contains("designer") ?? false)
        let other = FakeEmbedder(modelID: "other")
        let mismatched = try index.search(SearchRequest("designer"), queryVector: other.vector("designer"), queryModelID: "other")
        XCTAssertFalse(mismatched.semantic)
    }

    func testTopMomentsPerSourceCapAndFilters() async throws {
        let embedder = FakeEmbedder()
        let a = sampleMeeting(title: "Budget review")
        var b = sampleMeeting(title: "Other")
        b.segments = [segment("microphone:speaker-1", 0, 25, "The advertising budget is fine."),
                      segment("microphone:speaker-1", 25, 50, "Nothing else to add about lunch.")]
        try store.save(a); try store.save(b)
        // Long enough that the meeting splits into several chunks that all mention money.
        _ = try await MeetingIndexer(index: index, embedder: embedder).sync(store: store)
        let q = "advertising budget"
        let all = try index.search(SearchRequest(q, perSource: nil), queryVector: embedder.vector(q), queryModelID: embedder.modelID)
        let collapsed = try index.search(SearchRequest(q, perSource: 1), queryVector: embedder.vector(q), queryModelID: embedder.modelID)
        XCTAssertEqual(Set(collapsed.hits.map(\.ref)).count, collapsed.hits.count)
        XCTAssertGreaterThanOrEqual(all.hits.count, collapsed.hits.count)
        let onlyB = try index.search(SearchRequest(q, sourceRef: b.id), queryVector: embedder.vector(q), queryModelID: embedder.modelID)
        XCTAssertTrue(onlyB.hits.allSatisfy { $0.ref == b.id })
        XCTAssertFalse(onlyB.hits.isEmpty)
        let docsOnly = try index.search(SearchRequest(q, kinds: [.document]), queryVector: embedder.vector(q), queryModelID: embedder.modelID)
        XCTAssertTrue(docsOnly.hits.isEmpty)
    }

    func testRankingMathMatchesDigUp() {
        let z = Ranking.meaning([0.9, 0.5, 0.5, 0.5], [.text, .text, .text, .text])
        XCTAssertEqual(z[0], 1.732, accuracy: 0.01)
        var ranking = Ranking(); ranking.minimumForZ = 0
        let strong = Ranking.Candidate(z: 3, cosine: 0.8, coverage: 0, kindHinted: false)
        let weak = Ranking.Candidate(z: 1, cosine: 0.6, coverage: 0, kindHinted: false)
        let words = Ranking.Candidate(z: 1, cosine: 0.6, coverage: 1, kindHinted: false)
        XCTAssertEqual(ranking.score(strong, vectorCount: 1000, lookup: false)?.score ?? 0, 3, accuracy: 1e-9)
        XCTAssertNil(ranking.score(weak, vectorCount: 1000, lookup: false))
        XCTAssertEqual(ranking.score(words, vectorCount: 1000, lookup: false)?.score ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(ranking.score(words, vectorCount: 1000, lookup: true)?.score ?? 0, 4.5, accuracy: 1e-9)
        XCTAssertEqual(Ranking.strongCount([4, 3, 1.9, 1]), 2)
    }

    // MARK: Incremental reindex

    func testMeetingReindexIsIncremental() async throws {
        let embedder = FakeEmbedder()
        var meeting = sampleMeeting()
        try store.save(meeting)
        var recording = Meeting(title: "Live"); recording.segments = [segment("microphone:speaker-1", 0, 3, "In progress")]
        try store.save(recording)
        let indexer = MeetingIndexer(index: index, embedder: embedder)
        var report = try await indexer.sync(store: store)
        XCTAssertEqual(report.indexed, 1); XCTAssertEqual(report.skipped, 1)
        let calls = embedder.calls

        report = try await indexer.sync(store: store)
        XCTAssertEqual(report.unchanged, 1); XCTAssertEqual(embedder.calls, calls)

        // A named voice only rewrites keyword text.
        meeting.speakerAssignments = ["system:speaker-2": SpeakerAssignment(name: "Dana Whitfield")]
        meeting.voiceRevision = 1
        try store.save(meeting)
        report = try await indexer.sync(store: store)
        XCTAssertEqual(report.refreshed, 1); XCTAssertEqual(embedder.calls, calls)
        let byName = try index.search(SearchRequest("Whitfield"))
        XCTAssertTrue(byName.hits.contains { $0.speakers.contains("Dana Whitfield") })

        // Edited text re-embeds.
        meeting.segments[1].text = "We should double the advertising budget."
        try store.save(meeting)
        report = try await indexer.sync(store: store)
        XCTAssertEqual(report.indexed, 1); XCTAssertGreaterThan(embedder.calls, calls)

        // Deleted meetings leave.
        try FileManager.default.removeItem(at: try store.directory(meeting.id))
        report = try await indexer.sync(store: store)
        XCTAssertEqual(report.removed, 1)
        XCTAssertNil(try index.source(ref: meeting.id))
    }

    func testFolderReindexByMtimeAndHash() async throws {
        let embedder = FakeEmbedder()
        let docs = folder.appendingPathComponent("Docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        let note = docs.appendingPathComponent("plan.md")
        try "# Plan\n\nWe are hiring a designer and cutting marketing costs.".write(to: note, atomically: true, encoding: .utf8)
        try "<p>The contract was <b>signed</b>.</p>".write(to: docs.appendingPathComponent("legal.html"), atomically: true, encoding: .utf8)
        try "SECRET=1".write(to: docs.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "id".write(to: docs.appendingPathComponent("server.pem"), atomically: true, encoding: .utf8)
        try "dep".write(to: docs.appendingPathComponent("node_modules/readme.md"), atomically: true, encoding: .utf8)
        try Data(repeating: 0, count: 100).write(to: docs.appendingPathComponent("talk.m4a"))
        try index.addFolder(docs.path)
        let indexer = FolderIndexer(index: index, embedder: embedder)

        var report = try await indexer.sync()
        XCTAssertEqual(report.indexed, 2)
        XCTAssertEqual(report.skipped, 1)   // the plain extractor can't decode the .m4a; remembered as skipped
        XCTAssertEqual(Set(try index.sources(kind: .file).map { URL(fileURLWithPath: $0.ref).lastPathComponent }),
                       ["plan.md", "legal.html", "talk.m4a"])
        let calls = embedder.calls

        report = try await indexer.sync()
        XCTAssertEqual(report.indexed, 0); XCTAssertEqual(embedder.calls, calls)

        // Touched, same content: new fingerprint, no re-embed.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: note.path)
        report = try await indexer.sync()
        XCTAssertEqual(report.refreshed, 1); XCTAssertEqual(embedder.calls, calls)

        // Edited: re-read and re-embedded.
        try "# Plan\n\nThe database outage is fixed.".write(to: note, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: note.path)
        report = try await indexer.sync()
        XCTAssertEqual(report.indexed, 1); XCTAssertGreaterThan(embedder.calls, calls)
        let q = "incident"
        let hit = try index.search(SearchRequest(q), queryVector: embedder.vector(q), queryModelID: embedder.modelID).hits.first
        XCTAssertEqual(hit?.ref, note.standardizedFileURL.path)
        XCTAssertEqual(hit?.link, .file(path: note.standardizedFileURL.path, page: nil, seconds: nil))

        // Deleted files and removed folders leave.
        try FileManager.default.removeItem(at: note)
        report = try await indexer.sync()
        XCTAssertEqual(report.removed, 1)
        try index.removeFolder(docs.path)
        XCTAssertEqual(try index.sources(kind: .file).count, 0)
    }

    func testAudioWindowsSkipSilence() async throws {
        struct Tone: FileExtracting {
            func passages(of url: URL, kind: ChunkKind) async throws -> (title: String?, passages: [Passage]) { (nil, []) }
            func audioWindows(of url: URL, _ body: (AudioWindow) async throws -> Void) async throws {
                let tone = (0..<16_000).map { Float(sin(Double($0) * 0.1) * 0.2) }
                try await body(AudioWindow(start: 0, end: 10, samples: tone))
                try await body(AudioWindow(start: 10, end: 20, samples: [Float](repeating: 0.0005, count: 16_000)))
                try await body(AudioWindow(start: 20, end: 30, samples: tone))
            }
        }
        let embedder = FakeEmbedder()
        let file = folder.appendingPathComponent("memo.m4a")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: file)
        let indexer = FolderIndexer(index: index, embedder: embedder, extractor: Tone())
        try index.adopt(modelID: embedder.modelID)   // sync() does this; index(_:) alone doesn't
        let outcome = try await indexer.index(file, kind: .audio, root: folder.path)
        XCTAssertEqual(outcome, .indexed)
        XCTAssertEqual(try index.counts().vectors, 2)
        let q = "hum"
        let hits = try index.search(SearchRequest(q, perSource: nil), queryVector: embedder.vector(q), queryModelID: embedder.modelID).hits
        XCTAssertEqual(Set(hits.compactMap(\.start)), [0, 20])
        XCTAssertEqual(hits.first?.link, .file(path: file.path, page: nil, seconds: hits.first?.start))
    }

    // MARK: MCP and links

    func testSemanticSearchToolShape() async throws {
        let embedder = FakeEmbedder()
        let meeting = sampleMeeting()
        try store.save(meeting)
        _ = try await MeetingIndexer(index: index, embedder: embedder).sync(store: store)
        let url = index.url
        let server = MCPServer(store: store, embedder: embedder, openIndex: { try SearchIndex(url: url) })
        _ = server.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]])
        let list = server.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])!
        let tools = ((list["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        XCTAssertTrue(tools.contains { $0["name"] as? String == "semantic_search" })

        func call(_ args: [String: Any], with server: MCPServer) throws -> [String: Any] {
            let response = server.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                          "params": ["name": "semantic_search", "arguments": args]])!
            let result = try XCTUnwrap(response["result"] as? [String: Any])
            XCTAssertEqual(result["isError"] as? Bool, false, "\(result)")
            let text = try XCTUnwrap(((result["content"] as? [[String: Any]])?.first)?["text"] as? String)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        let body = try call(["query": "who is hiring", "limit": 5], with: server)
        XCTAssertEqual(body["semantic"] as? Bool, true)
        let first = try XCTUnwrap((body["results"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["meeting_id"] as? String, meeting.id)
        XCTAssertEqual(first["kind"] as? String, "meetingSegment")
        XCTAssertNotNil(first["start_seconds"] as? Double)
        XCTAssertNotNil(first["segment_id"] as? String)
        XCTAssertFalse((first["speaker_names"] as? [String])?.isEmpty ?? true)
        let link = try XCTUnwrap(URL(string: try XCTUnwrap(first["link"] as? String)))
        guard case .meeting(let id, let seconds, let segmentID)? = WorkScribeLink(url: link) else { return XCTFail("bad link \(link)") }
        XCTAssertEqual(id, meeting.id); XCTAssertNotNil(seconds); XCTAssertEqual(segmentID, first["segment_id"] as? String)

        // No model: keyword results, flagged; a meeting not yet indexed by the app is found by its words.
        var fresh = Meeting(title: "Fresh"); fresh.status = "complete"
        fresh.segments = [segment("microphone:speaker-1", 0, 5, "Quarterly roadmap for Zephyr")]
        try store.save(fresh)
        let bare = MCPServer(store: store, embedder: nil, openIndex: { try SearchIndex(url: url) })
        _ = bare.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]])
        let keyword = try call(["query": "Zephyr roadmap"], with: bare)
        XCTAssertEqual(keyword["semantic"] as? Bool, false)
        XCTAssertNotNil(keyword["note"] as? String)
        XCTAssertEqual((keyword["results"] as? [[String: Any]])?.first?["meeting_id"] as? String, fresh.id)
    }

    func testDeepLinksRoundTripAndRejectJunk() throws {
        let id = UUID().uuidString
        let links: [WorkScribeLink] = [.meeting(id: id, seconds: 12.5, segment: "seg-1"), .meeting(id: id, seconds: nil, segment: nil),
                                       .file(path: "/example/Docs/Q3 plan & notes+v2.pdf", page: 4, seconds: nil),
                                       .file(path: "/example/talk.m4a", page: nil, seconds: 90)]
        for link in links { XCTAssertEqual(WorkScribeLink(url: link.url), link, link.url.absoluteString) }
        XCTAssertEqual(WorkScribeLink(url: URL(string: "workscribe://meeting/\(id)?t=30&segment=abc")!),
                       .meeting(id: id, seconds: 30, segment: "abc"))
        XCTAssertNil(WorkScribeLink(url: URL(string: "workscribe://meeting/../../etc")!))
        XCTAssertNil(WorkScribeLink(url: URL(string: "workscribe://file?path=relative.txt")!))
        XCTAssertNil(WorkScribeLink(url: URL(string: "workscribe://file?path=/a/../b")!))
        XCTAssertNil(WorkScribeLink(url: URL(string: "https://meeting/\(id)")!))
    }
}
