import Foundation

extension SearchIndex {
    /// Called only by indexing/search executors, never the UI. Conversion is loss-limited f32 -> f16,
    /// without running the embedder or changing the model ID.
    private func convertLegacyVectors() throws {
        guard !readOnly else { return }
        var last: Int64 = 0
        while true {
            var rows: [(Int64, Data)] = []
            try db.query("SELECT id, vec FROM chunks WHERE vec IS NOT NULL AND vec_format = 0 AND id > ? ORDER BY id LIMIT 512", [.int(last)]) {
                if let blob = $0.blob(1) { rows.append(($0.int(0), blob)) }
            }
            guard !rows.isEmpty else { break }
            try db.transaction {
                for (id, data) in rows {
                    guard let vector = VectorEncoding.fullVector(data, dimension: data.count / 4, legacy: true) else { continue }
                    try db.run("UPDATE chunks SET vec = ?, vec_dim = ?, vec_format = 1 WHERE id = ? AND vec_format = 0",
                               [.blob(VectorEncoding.fullBlob(vector)), .int(Int64(vector.count)), .int(id)])
                }
            }
            last = rows.last!.0
        }
    }

    private func store() throws -> any VectorStore {
        if let suppliedVectorStore { return suppliedVectorStore }
        if let compactStore { return compactStore }
        let path = url.appendingPathExtension("vectors")
        let store: MappedVectorStore
        do { store = try MappedVectorStore(url: path) }
        catch {
            // A damaged derived file must never make the SQLite data inaccessible.
            // Serialize cache replacement against other readers/writers using the same lock inode.
            let lock = try MappedVectorStore.recover(url: path)
            store = lock
        }
        compactStore = store
        return store
    }

    /// Replay only changed chunk IDs. The read transaction pairs a journal high-water mark with its rows;
    /// a commit during the scan is picked up next time. Persisting the cursor follows fsync of all records.
    private func synchronize(_ store: any VectorStore) throws {
        if let namespace = try meta("vector_namespace").flatMap({ UInt64($0, radix: 16) }) { try store.setNamespace(namespace) }
        try db.readTransaction {
            var high: Int64 = 0
            try db.query("SELECT COALESCE(MAX(seq), 0) FROM vector_changes") { high = $0.int(0) }
            var cursor = try store.stats.checkpoint
            if cursor > high { // SQLite was replaced/restored; the file is only a cache.
                try store.reset(); cursor = 0
            }
            while cursor < high {
                var changes: [(Int64, Int64)] = []
                try db.query("SELECT seq, chunk_id FROM vector_changes WHERE seq > ? AND seq <= ? ORDER BY seq LIMIT 2048",
                             [.int(cursor), .int(high)]) { changes.append(($0.int(0), $0.int(1))) }
                guard let end = changes.last?.0 else { break }
                let ids = Set(changes.map(\.1))
                var found = Set<Int64>(), records: [VectorRecord] = []
                try db.query("""
                    SELECT c.id, c.source, c.kind, c.modality, c.start_s, c.end_s, c.vec, c.vec_dim, c.vec_format, s.started_at
                    FROM chunks c JOIN sources s ON s.id = c.source
                    WHERE c.id IN (\(ids.map(String.init).joined(separator: ","))) AND c.vec IS NOT NULL
                    """) { row in
                    guard let data = row.blob(6), let vector = VectorEncoding.fullVector(data,
                        dimension: row.isNull(7) ? data.count / 4 : Int(row.int(7)), legacy: row.int(8) == 0),
                        (try? VectorEncoding.truncated(vector)) != nil else { return }
                    let base = row.isNull(9) ? nil : row.double(9)
                    found.insert(row.int(0))
                    records.append(VectorRecord(id: row.int(0), sourceID: row.int(1),
                        kind: ChunkKind(rawValue: row.text(2) ?? "") ?? .document,
                        modality: Modality(rawValue: row.text(3) ?? "") ?? .none,
                        time: base.map { $0 + row.double(4) }, endTime: base.map { $0 + (row.isNull(5) ? row.double(4) : row.double(5)) }, vector: vector))
                }
                try store.delete(ids: Array(ids.subtracting(found)))
                try store.upsert(records)
                cursor = end
            }
            if high != (try store.stats.checkpoint) { try store.persist(checkpoint: high) }
        }
        let stats = try store.stats
        if stats.tombstones > max(4096, stats.count / 4) { try store.compact() }
    }

    public func purge(refs: [String]) throws {
        try db.run("PRAGMA secure_delete = ON")
        try db.transaction {
            for ref in refs {
                try setMeta("purged:" + ref, "1")
                try db.run("DELETE FROM meta WHERE substr(key,1,?)=?", [.int(Int64(("watch:" + ref + ":").count)), .text("watch:" + ref + ":")])
                try db.run("DELETE FROM lines WHERE source=?", [.text(ref)])
                try deleteRows(ref: ref)
            }
        }
        try db.run("INSERT INTO fts(fts) VALUES('optimize')")
        vectorLock.lock(); defer { vectorLock.unlock() }
        let vectors = try store()
        try vectors.withExclusiveAccess { try synchronize(vectors); try vectors.compact() }
        try db.run("PRAGMA wal_checkpoint(TRUNCATE)")
        try db.run("VACUUM")
        try db.run("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    public func vectorStats() throws -> VectorStoreStats {
        vectorLock.lock(); defer { vectorLock.unlock() }
        let store = try store()
        return try store.withExclusiveAccess { try convertLegacyVectors(); try synchronize(store); return try store.stats }
    }

    func semanticCandidates(_ query: [Float], request: SearchRequest, lexicalIDs: [Int64] = []) throws -> (meaning: [Int64: (z: Double, cosine: Float)], population: Int) {
        vectorLock.lock(); defer { vectorLock.unlock() }
        let store = try store()
        return try store.withExclusiveAccess {
            try convertLegacyVectors()
            return try db.readTransaction {
                try synchronize(store)
                var sourceIDs: Set<Int64>?
                if request.sourceRef != nil || request.sourceRefs != nil {
                    sourceIDs = []
                    var refs = request.sourceRefs ?? Set<String>()
                    if let single = request.sourceRef { refs = (request.sourceRefs?.contains(single) ?? true) ? [single] : [] }
                    let list = Array(refs)
                    for start in stride(from: 0, to: list.count, by: 500) {
                        let batch = Array(list[start..<min(list.count, start + 500)])
                        try db.query("SELECT id FROM sources WHERE ref IN (\(Array(repeating: "?", count: batch.count).joined(separator: ",")))", batch.map(SQLValue.text)) {
                            sourceIDs!.insert($0.int(0))
                        }
                    }
                }
                let candidates = try store.search(query: query, k: max(200, request.limit * 4),
                                                  filter: VectorFilter(kinds: request.kinds, sources: sourceIDs))
                // A deterministic corpus sample estimates the same full-vector modality distribution as
                // the old exhaustive path. Small indexes are exact. Never z-score just the top-k tail.
                var rows: [(id: Int64, score: Float, modality: Modality)] = []
                let sampleIDs = Set(try calibrationIDs())
                let ids = (candidates.matches.map(\.id) + lexicalIDs + Array(sampleIDs)).map(String.init).joined(separator: ",")
                var sample: [(Float, Modality)] = []
                try db.query("""
                    SELECT id, vec, vec_dim, vec_format, modality FROM chunks
                    WHERE vec IS NOT NULL AND id IN (\(ids.isEmpty ? "-1" : ids))
                    """) { row in
                    guard let data = row.blob(1), let vector = VectorEncoding.fullVector(data,
                        dimension: row.isNull(2) ? data.count / 4 : Int(row.int(2)), legacy: row.int(3) == 0),
                        vector.count == query.count, let unit = VectorMath.normalized(vector) else { return }
                    let score = VectorMath.dot(unit, query), modality = Modality(rawValue: row.text(4) ?? "") ?? .none
                    rows.append((row.int(0), score, modality))
                }
                // Keep the calibration sample independent of selected neighbors.
                sample = rows.filter { sampleIDs.contains($0.id) }.map { ($0.score, $0.modality) }
                let means = Ranking.modalityMeans(sample.map(\.0), sample.map(\.1))
                let centered = sample.map { Double($0.0) - means[$0.1, default: 0] }
                let mean = centered.reduce(0, +) / Double(max(1, centered.count))
                let deviation = max(0.02, (centered.reduce(0) { $0 + pow($1 - mean, 2) } / Double(max(1, centered.count))).squareRoot())
                let candidateIDs = Set(candidates.matches.map(\.id) + lexicalIDs)
                var meaning: [Int64: (z: Double, cosine: Float)] = [:]
                for row in rows where candidateIDs.contains(row.id) {
                    meaning[row.id] = ((Double(row.score) - means[row.modality, default: 0] - mean) / deviation, row.score)
                }
                // Use corpus population for the small-index cosine gate, as before filtering.
                let total = try store.stats.count
                return (meaning, total)
            }
        }
    }
    private func calibrationIDs() throws -> [Int64] {
        var ids: [Int64] = []
        try db.query("SELECT id FROM chunks WHERE vec IS NOT NULL ORDER BY (id * 1103515245 + 12345) & 2147483647 LIMIT 1024") { ids.append($0.int(0)) }
        return ids
    }
}
