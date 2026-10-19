import Foundation

public struct ChunkDelta: Sendable {
    public var added: [Chunk]
    public var removed: [String]
}
public struct QueryVector: Sendable {
    public var text: String
    public var vector: [Float]
    public var model: String
    public init(text: String, vector: [Float], model: String) { self.text = text; self.vector = vector; self.model = model }
}
public enum Scope: Sendable {
    case meeting(String, ClosedRange<Double>?)
    case linked(Set<SourceID>)
    case vault(excluding: Set<SourceID>)
}
public protocol Index: Sendable {
    func apply(_ revision: SourceRevision) throws -> ChunkDelta
    func setVectors(_ vectors: [String: [Float]], model: String) throws
    func candidates(_ query: QueryVector, scope: Scope, limit: Int) throws -> [Chunk]
    func purge(_ source: SourceID) throws
}

extension SearchIndex: Index {
    /// Publish words before admission to the embedder. Revisions retain unchanged row IDs and vectors.
    public func apply(_ revision: SourceRevision) throws -> ChunkDelta {
        var delta = ChunkDelta(added: [], removed: [])
        guard revision.passages.allSatisfy({ $0.source == revision.source }) else {
            throw Database.Failure(message: "Passage belongs to a different source")
        }
        let chunks = Chunker.chunks(revision)
        guard Set(chunks.map(\.id)).count == chunks.count else {
            throw Database.Failure(message: "Duplicate passage identity in source revision")
        }
        try db.transaction {
            guard try meta("purged:" + revision.source.ref) != "1",
                  try meta("purged:" + (revision.root ?? "")) != "1" else { return }
            let previousSource = try source(ref: revision.source.ref)
            if let old = previousSource {
                var stored = 0
                try db.query("SELECT revision FROM sources WHERE id = ?", [.int(old.id)]) { stored = Int($0.int(0)) }
                guard revision.revision >= stored else { return }
            }
            try db.run("""
                INSERT INTO sources(kind, ref, root, title, started_at, fingerprint, content_hash, model_id,
                                    voice_revision, state, detail, revision, source_kind)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(ref) DO UPDATE SET kind=excluded.kind, root=excluded.root, title=excluded.title,
                  started_at=excluded.started_at, fingerprint=excluded.fingerprint, content_hash=excluded.content_hash,
                  voice_revision=excluded.voice_revision, state=excluded.state, detail=excluded.detail, revision=excluded.revision, source_kind=excluded.source_kind
                """, [.text(revision.source.storageKind.rawValue), .text(revision.source.ref), .optional(revision.root),
                      .optional(revision.title), .optional(revision.startedAt?.timeIntervalSince1970), .text(revision.fingerprint),
                      .optional(revision.contentHash), .optional(vectorModel), .optional(revision.voiceRevision),
                      .text(revision.state), .optional(revision.detail), .int(Int64(revision.revision)), .text(revision.source.kind.rawValue)])
            guard let source = try source(ref: revision.source.ref) else { return }
            let previous = try sourceChunks(revision.source)
            let oldByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
            // Source-local reuse only. A purge never leaves a global document-vector cache behind.
            var reusable: [String: [Float]] = [:]
            for old in previous where old.modality == .text { if let vector = old.vector { reusable[Chunker.hash(old.embeddedText)] = vector } }
            let wanted = Set(chunks.map(\.id))
            for old in previous where !wanted.contains(old.id) {
                try db.run("DELETE FROM fts WHERE rowid = ?", [.int(old.seq)])
                try db.run("DELETE FROM chunks WHERE id = ?", [.int(old.seq)])
                delta.removed.append(old.id)
            }
            var sequence = max(Int64(try meta("chunk_seq") ?? "0") ?? 0, previous.map(\.seq).max() ?? 0)
            for var chunk in chunks {
                let hash = Chunker.hash(chunk.embeddedText)
                if let old = oldByID[chunk.id], old.context == chunk.context {
                    chunk.seq = old.seq
                    if old.speakers != chunk.speakers || old.speakerKeys != chunk.speakerKeys {
                        try db.run("UPDATE chunks SET speakers=?, speaker_keys=? WHERE id=?",
                                   [.text(Self.json(chunk.speakers)), .text(Self.json(chunk.speakerKeys)), .int(old.seq)])
                    }
                    if old.kind != chunk.kind || old.modality != chunk.modality || old.page != chunk.page
                        || old.track != chunk.track || old.anchorSegment != chunk.anchorSegment
                        || old.segmentIDs != chunk.segmentIDs || old.thumbnail != chunk.thumbnail || old.window != chunk.window {
                        try db.run("""
                            UPDATE chunks SET kind=?, modality=?, page=?, track=?, anchor_segment=?, segment_ids=?, thumbnail=?, window=? WHERE id=?
                            """, [.text(chunk.kind.rawValue), .text(chunk.modality.rawValue), .optional(chunk.page),
                                  .optional(chunk.track), .optional(chunk.anchorSegment), .text(Self.json(chunk.segmentIDs)),
                                  .optional(chunk.thumbnail), .optional(chunk.window), .int(old.seq)])
                    }
                    // Visual/audio adapters may replace a vector without changing their display text.
                    if let supplied = chunk.vector.flatMap(VectorMath.normalized),
                       old.vector.map(VectorEncoding.fullBlob) != VectorEncoding.fullBlob(supplied) {
                        try db.run("UPDATE chunks SET vec=?, vec_dim=?, vec_format=1 WHERE id=?",
                                   [.blob(VectorEncoding.fullBlob(supplied)), .int(Int64(supplied.count)), .int(old.seq)])
                    }
                    if old.start != chunk.start || old.end != chunk.end {
                        try db.run("UPDATE chunks SET start_s=?, end_s=? WHERE id=?",
                                   [.optional(chunk.start), .optional(chunk.end), .int(old.seq)])
                    }
                    if old.speakers != chunk.speakers || previousSource?.title != revision.title {
                        try db.run("UPDATE fts SET title=?, speakers=? WHERE rowid=?",
                                   [.optional(revision.title), .text(chunk.speakers.joined(separator: ", ")), .int(old.seq)])
                    }
                    continue
                }
                if let old = oldByID[chunk.id] {
                    try db.run("DELETE FROM fts WHERE rowid=?", [.int(old.seq)])
                    try db.run("DELETE FROM chunks WHERE id=?", [.int(old.seq)])
                    delta.removed.append(old.id)
                }
                sequence += 1; chunk.seq = sequence
                chunk.vector = chunk.vector ?? (chunk.modality == .text ? reusable[hash] : nil)
                try db.run("""
                    INSERT INTO chunks(id, source, kind, modality, start_s, end_s, page, track, anchor_segment,
                      segment_ids, speakers, speaker_keys, text, vec, thumbnail, window, vec_dim, vec_format,
                      chunk_key, anchor, context, embedded_hash)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?)
                    """, [.int(sequence), .int(source.id), .text(chunk.kind.rawValue), .text(chunk.modality.rawValue),
                          .optional(chunk.start), .optional(chunk.end), .optional(chunk.page), .optional(chunk.track),
                          .optional(chunk.anchorSegment), .text(Self.json(chunk.segmentIDs)), .text(Self.json(chunk.speakers)),
                          .text(Self.json(chunk.speakerKeys)), .optional(chunk.text),
                          chunk.vector.map { .blob(VectorEncoding.fullBlob($0)) } ?? .null, .optional(chunk.thumbnail),
                          .optional(chunk.window), .optional(chunk.vector?.count), .text(chunk.id), .text(chunk.anchor),
                          .optional(chunk.context), .text(hash)])
                try db.run("INSERT INTO fts(rowid,title,speakers,body) VALUES(?,?,?,?)",
                           [.int(sequence), .optional(revision.title), .text(chunk.speakers.joined(separator: ", ")),
                            .text(SearchText.normalized(chunk.embeddedText))])
                delta.added.append(chunk)
            }
            try setMeta("chunk_seq", String(sequence))
            let data = try JSONSerialization.data(withJSONObject: revision.metadata, options: [.sortedKeys])
            try db.run("INSERT INTO source_meta(ref,json) VALUES(?,?) ON CONFLICT(ref) DO UPDATE SET json=excluded.json",
                       [.text(revision.source.ref), .text(String(decoding: data, as: UTF8.self))])
        }
        if !delta.added.isEmpty || !delta.removed.isEmpty { invalidate() }
        return delta
    }

    public func sourceChunks(_ source: SourceID, ids: Set<Int64>? = nil) throws -> [Chunk] {
        if let ids, ids.isEmpty { return [] }
        let selection = ids.map { " AND c.id IN (" + $0.sorted().map(String.init).joined(separator: ",") + ")" } ?? ""
        var chunks: [Chunk] = []
        try db.query("""
            SELECT c.id,c.chunk_key,c.kind,c.modality,c.start_s,c.end_s,c.page,c.track,c.anchor_segment,
                   c.segment_ids,c.speakers,c.speaker_keys,c.text,c.vec,c.thumbnail,c.window,c.vec_dim,c.vec_format,c.anchor,c.context,s.source_kind
            FROM chunks c JOIN sources s ON c.source=s.id WHERE s.ref=?\(selection) ORDER BY c.id
            """, [.text(source.ref)]) { row in
            var chunk = Chunk(kind: ChunkKind(rawValue: row.text(2) ?? "") ?? .document,
                              modality: Modality(rawValue: row.text(3) ?? "") ?? .text,
                              start: row.isNull(4) ? nil : row.double(4), end: row.isNull(5) ? nil : row.double(5),
                              page: row.isNull(6) ? nil : Int(row.int(6)), track: row.text(7), anchorSegment: row.text(8),
                              segmentIDs: Self.strings(row.text(9)), speakers: Self.strings(row.text(10)),
                              speakerKeys: Self.strings(row.text(11)), text: row.text(12),
                              thumbnail: row.text(14), window: row.text(15))
            chunk.seq = row.int(0); chunk.id = row.text(1) ?? "legacy:\(chunk.seq)"
            chunk.source = SourceID(SourceID.Kind(rawValue: row.text(20) ?? "") ?? source.kind, source.ref); chunk.anchor = row.text(18) ?? ""; chunk.context = row.text(19)
            if let data = row.blob(13) {
                chunk.vector = VectorEncoding.fullVector(data, dimension: row.isNull(16) ? data.count / 4 : Int(row.int(16)), legacy: row.int(17) == 0)
            }
            chunks.append(chunk)
        }
        return chunks
    }

    public func setVectors(_ vectors: [String: [Float]], model: String) throws {
        try writeVectors(vectors, model: model, expected: [:])
    }
    private func writeVectors(_ vectors: [String: [Float]], model: String, expected: [String: String]) throws {
        try db.transaction {
            guard vectorModel == model else { return }
            for (id, value) in vectors.sorted(by: { $0.key < $1.key }) {
                guard let vector = VectorMath.normalized(value) else { continue }
                try db.run("""
                    UPDATE chunks SET vec=?, vec_dim=?, vec_format=1 WHERE chunk_key=?
                    AND (? IS NULL OR embedded_hash=?) AND source IN
                    (SELECT id FROM sources WHERE ref NOT IN (SELECT substr(key,8) FROM meta WHERE key LIKE 'purged:%' AND value='1')
                    AND COALESCE(root,'') NOT IN (SELECT substr(key,8) FROM meta WHERE key LIKE 'purged:%' AND value='1'))
                    """, [.blob(VectorEncoding.fullBlob(vector)), .int(Int64(vector.count)), .text(id),
                          .optional(expected[id]), .optional(expected[id])])
            }
        }
        invalidate()
    }

    public func embedMissing(_ source: SourceID, using embedder: any Embedder,
                             gate: @Sendable () async -> Void = {}) async throws {
        try adopt(modelID: embedder.modelID)
        let pending = try sourceChunks(source).filter { $0.vector == nil && $0.modality == .text && SearchText.hasWords($0.embeddedText) }
        var groups: [String: [String]] = [:], texts: [String] = []
        for chunk in pending {
            if groups[chunk.embeddedText] == nil { texts.append(chunk.embeddedText) }
            groups[chunk.embeddedText, default: []].append(chunk.id)
        }
        for start in stride(from: 0, to: texts.count, by: 2) {
            await gate(); try Task.checkCancellation()
            let batch = Array(texts[start..<min(start + 2, texts.count)])
            let vectors = try await embedder.texts(batch, role: .document(title: nil))
            guard vectors.count == batch.count else { throw Database.Failure(message: "Embedding batch count mismatch") }
            var updates: [String: [Float]] = [:], expected: [String: String] = [:]
            for (text, vector) in zip(batch, vectors) {
                for id in groups[text] ?? [] { updates[id] = vector; expected[id] = Chunker.hash(text) }
            }
            // Heading changes preserve ChunkID but change the embedding input; reject that late result too.
            try writeVectors(updates, model: embedder.modelID, expected: expected)
        }
        try db.run("UPDATE sources SET model_id=? WHERE ref=? AND NOT EXISTS (SELECT 1 FROM chunks WHERE source=sources.id AND modality='text' AND vec IS NULL)",
                   [.text(embedder.modelID), .text(source.ref)])
    }

    /// OCR is already searchable before optional visual inference is admitted.
    public func embedImages(_ source: SourceID, using embedder: any Embedder,
                            gate: @Sendable () async -> Void = {}) async throws {
        guard embedder.supportsImages else { return }
        for chunk in try sourceChunks(source) where chunk.modality == .image && chunk.vector == nil {
            guard let path = chunk.thumbnail else { continue }
            await gate(); try Task.checkCancellation()
            if let vector = try? await embedder.image(URL(fileURLWithPath: path)) {
                try writeVectors([chunk.id: vector], model: embedder.modelID,
                                 expected: [chunk.id: Chunker.hash(chunk.embeddedText)])
            }
        }
    }

    public func candidates(_ query: QueryVector, scope: Scope, limit: Int) throws -> [Chunk] {
        guard query.model == vectorModel, limit > 0 else { return [] }
        let sources: [SourceID]
        switch scope {
        case .meeting(let id, _): sources = [SourceID(.meeting, id)]
        case .linked(let ids): sources = ids.sorted { $0.key < $1.key }
        case .vault(let excluded):
            let refs = Set(excluded.map(\.ref))
            sources = try ([SourceKind.vault, .file].flatMap { try self.sources(kind: $0) })
                .filter { !refs.contains($0.ref) }.map { SourceID($0.kind == .vault ? .vault : .folder, $0.ref) }
        }
        var selectedIDs: Set<Int64>?
        if case .meeting = scope {} else {
            let request = SearchRequest(query.text, limit: 48, perSource: nil, sourceRefs: Set(sources.map(\.ref)))
            let result = try semanticCandidates(query.vector, request: request)
            selectedIDs = Set(result.meaning.sorted {
                $0.value.cosine == $1.value.cosine ? $0.key < $1.key : $0.value.cosine > $1.value.cosine
            }.prefix(48).map(\.key))
            let terms = SearchText.patterns(SearchText.terms(query.text), prefixLast: false)
            if !terms.isEmpty {
                let refs = sources.map(\.ref)
                let placeholders = Array(repeating: "?", count: refs.count).joined(separator: ",")
                try db.query("""
                    SELECT c.id FROM fts JOIN chunks c ON c.id=fts.rowid JOIN sources s ON s.id=c.source
                    WHERE fts MATCH ? AND c.vec IS NOT NULL AND s.ref IN (\(placeholders))
                    ORDER BY bm25(fts), c.id LIMIT 24
                    """, [.text(terms.joined(separator: " OR "))] + refs.map(SQLValue.text)) { selectedIDs!.insert($0.int(0)) }
            }
        }
        let chunks = try sources.flatMap { try sourceChunks($0, ids: selectedIDs) }.filter { chunk in
            guard chunk.vector?.count == query.vector.count else { return false }
            if case .meeting(_, let range?) = scope {
                return (chunk.start ?? .infinity) <= range.upperBound && (chunk.end ?? -.infinity) >= range.lowerBound
            }
            return true
        }
        let scored = chunks.map { ($0, VectorMath.dot(query.vector, $0.vector!)) }
        return scored.sorted { $0.1 == $1.1 ? $0.0.seq < $1.0.seq : $0.1 > $1.1 }
            .prefix(limit).map(\.0)
    }
    public func purge(_ source: SourceID) throws { try purge(refs: [source.ref]) }
}

extension SearchIndex {
    public func watch(source: SourceID, query: String) throws -> Watch {
        guard let stored = try meta("watch:" + source.ref + ":" + query) else { return Watch() }
        return try JSONDecoder().decode(Watch.self, from: Data(stored.utf8))
    }
    public func saveWatch(_ watch: Watch, source: SourceID, query: String) throws {
        try db.transaction {
            guard try meta("purged:" + source.ref) != "1" else { return }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try setMeta("watch:" + source.ref + ":" + query, String(decoding: encoder.encode(watch), as: UTF8.self))
        }
    }
}
