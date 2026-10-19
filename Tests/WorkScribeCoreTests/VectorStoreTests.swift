import XCTest
@testable import WorkScribeCore

final class VectorStoreTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ws-vectors-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    func vector(_ seed: Int, dimension: Int = 768) -> [Float] {
        VectorMath.normalized((0..<dimension).map { Float(sin(Double($0 * 13 + seed * 7 + 1))) })!
    }
    func record(_ id: Int64, kind: ChunkKind = .document, source: Int64 = 1, time: Double? = nil) -> VectorRecord {
        VectorRecord(id: id, sourceID: source, kind: kind, time: time, endTime: time.map { $0 + 10 }, vector: vector(Int(id)))
    }
    func testTruncateThenRenormalizeAndRejectBadVectors() throws {
        let original = vector(1), truncated = try VectorEncoding.truncated(original)
        XCTAssertEqual(truncated.count, 256)
        XCTAssertEqual(VectorMath.dot(truncated, truncated), 1, accuracy: 0.00001)
        XCTAssertEqual(truncated[50] / truncated[80], original[50] / original[80], accuracy: 0.00001)
        XCTAssertThrowsError(try VectorEncoding.truncated(Array(repeating: 0, count: 768)))
        XCTAssertThrowsError(try VectorEncoding.truncated([.nan, 1]))
        let padded = try VectorEncoding.truncated([3, 4])
        XCTAssertEqual(padded[0], 0.6, accuracy: 0.00001)
        XCTAssertTrue(padded.dropFirst(2).allSatisfy { $0 == 0 })
    }
    func testQuantizationErrorBoundAndSIMDOverflow() throws {
        for seed in 1...50 {
            let unit = try VectorEncoding.truncated(vector(seed)), q = try VectorEncoding.quantize(unit)
            for i in 0..<256 { XCTAssertLessThanOrEqual(abs(unit[i] - Float(q.values[i]) * q.scale), q.scale * 0.501) }
            let reconstructed = q.values.map { Float($0) * q.scale }
            XCTAssertGreaterThan(VectorMath.dot(unit, VectorMath.normalized(reconstructed)!), 0.9999)
        }
        let full = Array(repeating: Int8(127), count: 256)
        let dot = full.withUnsafeBytes { a in full.withUnsafeBytes { b in MappedVectorStore.int8Dot(a.baseAddress!, b.baseAddress!) } }
        XCTAssertEqual(dot, 256 * 127 * 127)
    }
    func testFiltersIncludingEmptySetsAndUndated() throws {
        let s = try MappedVectorStore(url: root.appendingPathComponent("vectors"))
        try s.upsert([record(1, kind: .screen, source: 10, time: 100), record(2, kind: .audio, source: 20, time: 200), record(3)])
        XCTAssertEqual(try s.search(query: vector(1), k: 10, filter: VectorFilter(kinds: [.screen])).matches.map(\.id), [1])
        XCTAssertEqual(try s.search(query: vector(1), k: 10, filter: VectorFilter(sources: [20])).matches.map(\.id), [2])
        XCTAssertEqual(try s.search(query: vector(1), k: 10, filter: VectorFilter(timeRange: 110...110)).matches.map(\.id), [1])
        XCTAssertTrue(try s.search(query: vector(1), k: 10, filter: VectorFilter(sources: [])).matches.isEmpty)
        XCTAssertTrue(try s.search(query: vector(1), k: 10, filter: VectorFilter(kinds: [])).matches.isEmpty)
        XCTAssertTrue(try s.search(query: vector(1), k: 0).matches.isEmpty)
    }
    func testPersistenceReplacementTombstonesAndCompaction() throws {
        let path = root.appendingPathComponent("vectors")
        do {
            let s = try MappedVectorStore(url: path)
            try s.upsert([record(1), record(2), record(3)])
            try s.upsert([record(1, source: 4), record(1, source: 5)])
            try s.delete(ids: [2, 900])
            try s.persist(checkpoint: 42)
            XCTAssertEqual(try s.stats.count, 2)
            XCTAssertEqual(try s.stats.tombstones, 3)
        }
        let s = try MappedVectorStore(url: path)
        XCTAssertEqual(try s.stats.checkpoint, 42)
        XCTAssertEqual(try s.search(query: vector(1), k: 10).matches.map(\.id).sorted(), [1, 3])
        try s.compact()
        XCTAssertEqual(try s.stats.tombstones, 0)
        XCTAssertEqual(try s.stats.mappedBytes, 64 + 320 * 2)
        XCTAssertEqual(try s.stats.checkpoint, 42)
        XCTAssertEqual(try s.search(query: vector(1), k: 1, filter: VectorFilter(sources: [5])).matches.first?.id, 1)
    }
    func testSecondInstanceObservesUpdatesAndCompaction() throws {
        let path = root.appendingPathComponent("vectors"), a = try MappedVectorStore(url: path), b = try MappedVectorStore(url: path)
        try a.upsert([record(1)])
        XCTAssertEqual(try b.stats.count, 1)
        try b.delete(ids: [1]); try b.compact()
        XCTAssertEqual(try a.stats.count, 0)
        try a.upsert([record(2)])
        XCTAssertEqual(try b.search(query: vector(2), k: 1).matches.first?.id, 2)
    }
    func testSIMDAndVDSPParity() throws {
        let s = try MappedVectorStore(url: root.appendingPathComponent("vectors"))
        try s.upsert((1...300).map { record(Int64($0)) })
        let a = try s.search(query: vector(42), k: 20)
        s.kernel = .vdsp
        let b = try s.search(query: vector(42), k: 20)
        XCTAssertEqual(a.matches.map(\.id), b.matches.map(\.id))
        for (x, y) in zip(a.matches, b.matches) { XCTAssertEqual(x.score, y.score, accuracy: 0.00001) }
    }
    func testMigrationRetainsModelAndConvertsFullVectorsWithoutEmbedding() throws {
        let path = root.appendingPathComponent("index.sqlite"), v = vector(4)
        do {
            let db = try Database(path: path.path)
            try db.execute(SearchIndex.migrations[0]); try db.execute(SearchIndex.migrations[1]); try db.execute("PRAGMA user_version = 2")
            try db.execute("INSERT INTO sources(kind,ref,fingerprint) VALUES('meeting','m','f'); INSERT INTO meta VALUES('vector_model','model')")
            try db.run("INSERT INTO chunks(source,kind,modality,vec,text) VALUES(1,'meetingSegment','text',?,'legacy')", [.blob(VectorMath.blob(v))])
            try db.execute("INSERT INTO fts(rowid,body) VALUES(1,'legacy')")
        }
        let index = try SearchIndex(url: path)
        XCTAssertEqual(index.userVersion, SearchIndex.schemaVersion)
        XCTAssertEqual(index.vectorModel, "model")
        XCTAssertEqual(try index.vectorStats().count, 1)
        try index.db.query("SELECT length(vec),vec_dim,vec_format FROM chunks") {
            XCTAssertEqual($0.int(0), 1536); XCTAssertEqual($0.int(1), 768); XCTAssertEqual($0.int(2), 1)
        }
        XCTAssertEqual(try index.search(SearchRequest("unmatched"), queryVector: v, queryModelID: "model").hits.first?.ref, "m")
        try index.adopt(modelID: "other")
        XCTAssertEqual(try index.vectorStats().count, 0)
    }
    func testSmallFixtureRankingParityWithOldFullPath() throws {
        let index = try SearchIndex(url: root.appendingPathComponent("index.sqlite"))
        try index.adopt(modelID: "m")
        let vectors = (1...30).map { vector($0) }
        try index.replace(kind: .file, ref: "a", title: "fixture", fingerprint: "1", modelID: "m",
                          chunks: vectors.map { Chunk(kind: .document, modality: .text, vector: $0) })
        let q = vector(8), cosine = vectors.map { VectorMath.dot(q, $0) }
        let z = Ranking.meaning(cosine, Array(repeating: .text, count: cosine.count))
        let old = cosine.indices.compactMap { i -> (Int64, Double)? in
            guard let score = index.ranking.score(.init(z: z[i], cosine: cosine[i], coverage: 0, kindHinted: false), vectorCount: vectors.count, lookup: false) else { return nil }
            return (Int64(i + 1), score.score)
        }.sorted { $0.1 > $1.1 }
        let hits = try index.search(SearchRequest("unmatched", limit: 100, perSource: nil), queryVector: q, queryModelID: "m").hits
        XCTAssertEqual(hits.map(\.chunkID), old.map(\.0))
        for (hit, prior) in zip(hits, old) { XCTAssertEqual(hit.score, prior.1, accuracy: 0.002) }
    }
    func testParallelScanHasStableTiesAndRespectsNamespace() throws {
        let s = try MappedVectorStore(url: root.appendingPathComponent("vectors"), workers: 1)
        let records = (1...20000).map { VectorRecord(id: Int64($0), sourceID: 1, kind: .document, vector: [1, 0, 0]) }
        try s.upsert(records)
        let serial = try s.search(query: [1, 0, 0], k: 10).matches.map(\.id)
        s.workers = 4
        XCTAssertEqual(try s.search(query: [1, 0, 0], k: 10).matches.map(\.id), serial)
        XCTAssertEqual(serial, Array(1...10).map(Int64.init))
        try s.setNamespace(123)
        XCTAssertEqual(try s.stats.count, 0)
        try s.upsert([record(1)])
        try s.persist(checkpoint: 7)
        try s.setNamespace(123)
        XCTAssertEqual(try s.stats.count, 1)
        try s.setNamespace(456)
        XCTAssertEqual(try s.stats.count, 0)
        XCTAssertEqual(try s.stats.checkpoint, 0)
    }

    func testSteadyStateSQLUsesBoundedIndexes() throws {
        let index = try SearchIndex(url: root.appendingPathComponent("index.sqlite"))
        func plan(_ sql: String) throws -> String {
            var details: [String] = []
            try index.db.query("EXPLAIN QUERY PLAN " + sql) { details.append($0.text(3) ?? "") }
            return details.joined(separator: " ")
        }
        XCTAssertTrue(try plan("SELECT id,vec FROM chunks WHERE vec IS NOT NULL AND vec_format = 0 AND id > 0 ORDER BY id LIMIT 512").contains("chunks_legacy_vector"))
        XCTAssertTrue(try plan("SELECT id FROM chunks WHERE vec IS NOT NULL ORDER BY (id * 1103515245 + 12345) & 2147483647 LIMIT 1024").contains("chunks_vector_sample"))
    }

    func testJournalDeletionReusedIDsRecoveryAndReadOnly() throws {
        let path = root.appendingPathComponent("index.sqlite")
        let a = try SearchIndex(url: path)
        try a.adopt(modelID: "m")
        func replace(_ n: Int) throws { try a.replace(kind: .file, ref: "a", title: "a", fingerprint: "\(n)", modelID: "m", chunks: [Chunk(kind: .document, modality: .text, vector: vector(n))]) }
        try replace(1); XCTAssertEqual(try a.vectorStats().count, 1)
        let b = try SearchIndex(url: path, readOnly: true)
        try replace(2)
        XCTAssertEqual(try b.search(SearchRequest("zz"), queryVector: vector(2), queryModelID: "m").hits.first?.ref, "a")
        try a.remove(ref: "a"); XCTAssertEqual(try b.vectorStats().count, 0)
        try replace(3)
        a.invalidate(); b.invalidate()
        try Data("torn cache".utf8).write(to: path.appendingPathExtension("vectors"))
        XCTAssertEqual(try a.vectorStats().count, 1)
    }
}
