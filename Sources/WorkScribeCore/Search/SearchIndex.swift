import Foundation

/// What a chunk is a piece of.
public enum ChunkKind: String, Sendable, CaseIterable {
    case meetingSegment, document, audio, video, image
    /// Text read off the screen during a meeting (`ScreenMoment`).
    case screen
    /// A web clip: a Web Clipper note or a page sent from the WorkScribe extension.
    case clip
}

/// `vault` is a Markdown note in the user's vault (or WorkScribe's notes folder), indexed structurally.
public enum SourceKind: String, Sendable { case meeting, file, vault }

/// One searchable moment: a span of a meeting, a page or passage of a document, a window of a recording.
public struct Chunk: Sendable, Equatable {
    public var id: String = ""
    public var seq: Int64 = 0
    public var source: SourceID = SourceID(.folder, "")
    public var anchor: String = ""
    public var context: String?
    public var embeddedText: String { [context, text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n") }
    public var kind: ChunkKind
    public var modality: Modality
    public var start: Double?
    public var end: Double?
    public var page: Int?
    public var track: String?
    /// The meeting segment to deep-link to, and every segment the chunk covers.
    public var anchorSegment: String?
    public var segmentIDs: [String]
    /// Display names at indexing time ("Alice, Speaker 2"); refreshed without re-embedding when voices change.
    public var speakers: [String]
    /// Raw diarization keys ("system:speaker-2"), so names can be re-resolved.
    public var speakerKeys: [String]
    /// Exactly what was embedded (nil for audio windows).
    public var text: String?
    public var vector: [Float]?
    /// Screen moments: an absolute path to the moment's thumbnail, and "App — Window".
    public var thumbnail: String?
    public var window: String?

    public init(kind: ChunkKind, modality: Modality, start: Double? = nil, end: Double? = nil, page: Int? = nil,
                track: String? = nil, anchorSegment: String? = nil, segmentIDs: [String] = [], speakers: [String] = [],
                speakerKeys: [String] = [], text: String? = nil, vector: [Float]? = nil, thumbnail: String? = nil,
                window: String? = nil) {
        self.kind = kind; self.modality = modality; self.start = start; self.end = end; self.page = page
        self.track = track; self.anchorSegment = anchorSegment; self.segmentIDs = segmentIDs; self.speakers = speakers
        self.speakerKeys = speakerKeys; self.text = text; self.vector = vector; self.thumbnail = thumbnail
        self.window = window
    }
}

/// The bookkeeping row for a meeting or a file.
public struct IndexedSource: Sendable, Equatable {
    public var id: Int64
    public var kind: SourceKind
    public var ref: String
    public var root: String?
    public var title: String?
    public var fingerprint: String
    public var contentHash: String?
    public var modelID: String?
    public var voiceRevision: Int?
    public var state: String
    public var detail: String?
}

public struct SearchRequest: Sendable {
    public var text: String
    public var limit: Int
    /// At most this many moments per meeting or file; 1 collapses to the best moment per source; nil is no cap.
    public var perSource: Int?
    public var kinds: Set<ChunkKind>?
    /// Only this meeting ID or file path.
    public var sourceRef: String?
    /// Only these meeting IDs or file paths (a conversation's attachments); nil is no restriction.
    public var sourceRefs: Set<String>?
    public var prefixLast: Bool
    public init(_ text: String, limit: Int = 20, perSource: Int? = 3, kinds: Set<ChunkKind>? = nil,
                sourceRef: String? = nil, sourceRefs: Set<String>? = nil, prefixLast: Bool = false) {
        self.text = text; self.limit = limit; self.perSource = perSource; self.kinds = kinds
        self.sourceRef = sourceRef; self.sourceRefs = sourceRefs; self.prefixLast = prefixLast
    }
}

public struct SearchHit: Sendable {
    public var chunkID: Int64
    public var sourceKind: SourceKind
    /// Meeting ID or file path.
    public var ref: String
    public var title: String?
    public var kind: ChunkKind
    public var start: Double?
    public var end: Double?
    public var page: Int?
    public var track: String?
    public var anchorSegment: String?
    public var segmentIDs: [String]
    public var speakers: [String]
    public var text: String?
    public var snippet: String?
    public var score: Double
    public var z: Double?
    public var cosine: Float?
    public var match: Ranking.Match
    /// Screen moments only.
    public var thumbnail: String? = nil
    public var window: String? = nil
    /// Per-source facts the indexer recorded (vault notes: `path`, `vault`, `type`, `url`, `site`, `clipped`,
    /// `highlights`, `meeting_id`…). Empty for meetings and folder files.
    public var meta: [String: String] = [:]
    public var link: WorkScribeLink {
        switch sourceKind {
        case .meeting: .meeting(id: ref, seconds: start, segment: anchorSegment)
        case .file, .vault: .file(path: ref, page: page, seconds: start)
        }
    }
    /// Opens the note in Obsidian, for vault notes in a folder Obsidian knows as a vault.
    public var obsidianURL: URL? {
        guard sourceKind == .vault, let vault = meta["vault"], let path = meta["path"] else { return nil }
        return VaultLinks.obsidian(vault: vault, file: path)
    }
}

public struct SearchResults: Sendable {
    public var hits: [SearchHit]
    /// Whether meaning was used (a query vector from the index's model was given).
    public var semantic: Bool
    /// How many leading hits are strong (`Ranking.strongCount`).
    public var strong: Int
}

/// The semantic + keyword index of meetings and files: one SQLite file (sources, chunks with Float32 vector BLOBs,
/// an FTS5 table whose rowid is the chunk id), searched by an in-memory Accelerate dot product. It is a derived
/// cache: deleting it loses nothing that indexing can't rebuild.
///
/// Schema after DigUp's `IndexStore` (vectors next to their metadata, the vector model recorded in `meta`).
public final class SearchIndex: @unchecked Sendable {
    public static let schemaVersion = 4
    public let url: URL
    public let db: Database
    public var ranking = Ranking()
    let vectorLock = NSRecursiveLock()
    var compactStore: (any VectorStore)?
    let readOnly: Bool
    let suppliedVectorStore: (any VectorStore)?

    public static var defaultURL: URL {
        if let dir = ProcessInfo.processInfo.environment["WORKSCRIBE_INDEX_DIR"] {
            return URL(fileURLWithPath: dir).appendingPathComponent("index.sqlite")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WorkScribe/Index/index.sqlite")
    }

    public convenience init(url: URL = SearchIndex.defaultURL, readOnly: Bool = false) throws {
        try self.init(url: url, readOnly: readOnly, vectorStore: nil)
    }

    public init(url: URL, readOnly: Bool, vectorStore: (any VectorStore)?) throws {
        self.url = url
        self.readOnly = readOnly
        self.compactStore = vectorStore
        self.suppliedVectorStore = vectorStore
        if !readOnly {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        db = try Database(path: url.path, readOnly: readOnly)
        if !readOnly { try migrate(); try db.execute(Self.metaTable); try db.execute(Self.linesTable) }
    }

    /// Facts about a source that aren't searchable text (a clip's URL, a note's vault path). Kept out of the numbered
    /// migrations so it can't collide with schema changes made in parallel; it's a derived cache like the rest.
    static let metaTable = "CREATE TABLE IF NOT EXISTS source_meta(ref TEXT PRIMARY KEY, json TEXT NOT NULL)"
    private lazy var hasMetaTable: Bool = {
        (try? db.scalar("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'source_meta'")) != nil
    }()

    public func meta(ref: String) throws -> [String: String] {
        guard hasMetaTable, let json = try db.scalar("SELECT json FROM source_meta WHERE ref = ?", [.text(ref)]),
              let data = json.data(using: .utf8) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: String]) ?? [:]
    }

    // MARK: Schema

    static let migrations: [String] = [
        // 1
        """
        CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE folders(path TEXT PRIMARY KEY, added_at REAL NOT NULL);
        CREATE TABLE sources(
          id INTEGER PRIMARY KEY,
          kind TEXT NOT NULL,
          ref TEXT NOT NULL UNIQUE,
          root TEXT,
          title TEXT,
          started_at REAL,
          fingerprint TEXT NOT NULL,
          content_hash TEXT,
          model_id TEXT,
          voice_revision INTEGER,
          state TEXT NOT NULL DEFAULT 'indexed',
          detail TEXT,
          indexed_at REAL
        );
        CREATE TABLE chunks(
          id INTEGER PRIMARY KEY,
          source INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
          kind TEXT NOT NULL,
          modality TEXT NOT NULL,
          start_s REAL, end_s REAL, page INTEGER, track TEXT,
          anchor_segment TEXT, segment_ids TEXT, speakers TEXT, speaker_keys TEXT,
          text TEXT,
          vec BLOB
        );
        CREATE INDEX chunks_source ON chunks(source);
        CREATE VIRTUAL TABLE fts USING fts5(title, speakers, body, tokenize = "\(SearchText.tokenizer)");
        """,
        // 2: screen moments
        """
        ALTER TABLE chunks ADD COLUMN thumbnail TEXT;
        ALTER TABLE chunks ADD COLUMN window TEXT;
        """,
        // 3: compact vector cache journal and full float16 vectors. Existing blobs remain f32 until
        // the first off-main vector synchronization converts them in bounded batches.
        """
        INSERT INTO meta(key, value) VALUES('vector_namespace', lower(hex(randomblob(8))));
        ALTER TABLE chunks ADD COLUMN vec_dim INTEGER;
        ALTER TABLE chunks ADD COLUMN vec_format INTEGER NOT NULL DEFAULT 0;
        CREATE TABLE vector_changes(seq INTEGER PRIMARY KEY AUTOINCREMENT, chunk_id INTEGER NOT NULL);
        CREATE INDEX vector_changes_chunk ON vector_changes(chunk_id);
        CREATE INDEX chunks_legacy_vector ON chunks(id) WHERE vec IS NOT NULL AND vec_format = 0;
        CREATE INDEX chunks_vector_sample ON chunks((id * 1103515245 + 12345) & 2147483647) WHERE vec IS NOT NULL;
        INSERT INTO vector_changes(chunk_id) SELECT id FROM chunks WHERE vec IS NOT NULL;
        CREATE TRIGGER vector_insert AFTER INSERT ON chunks WHEN NEW.vec IS NOT NULL BEGIN
          INSERT INTO vector_changes(chunk_id) VALUES(NEW.id);
        END;
        CREATE TRIGGER vector_update AFTER UPDATE OF vec, kind, modality, start_s, end_s ON chunks BEGIN
          INSERT INTO vector_changes(chunk_id) VALUES(NEW.id);
        END;
        CREATE TRIGGER vector_delete AFTER DELETE ON chunks WHEN OLD.vec IS NOT NULL BEGIN
          INSERT INTO vector_changes(chunk_id) VALUES(OLD.id);
        END;
        CREATE TRIGGER vector_source_time AFTER UPDATE OF started_at ON sources BEGIN
          INSERT INTO vector_changes(chunk_id) SELECT id FROM chunks WHERE source = NEW.id AND vec IS NOT NULL;
        END;
        """,
        // Immutable content identity and monotonic watermarks survive deletions and restart.
        """
        ALTER TABLE chunks ADD COLUMN chunk_key TEXT;
        ALTER TABLE chunks ADD COLUMN anchor TEXT;
        ALTER TABLE chunks ADD COLUMN context TEXT;
        ALTER TABLE chunks ADD COLUMN embedded_hash TEXT;
        CREATE UNIQUE INDEX chunks_key ON chunks(chunk_key) WHERE chunk_key IS NOT NULL;
        INSERT INTO meta(key, value) SELECT 'chunk_seq', CAST(COALESCE(MAX(id), 0) AS TEXT) FROM chunks;
        ALTER TABLE sources ADD COLUMN revision INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE sources ADD COLUMN source_kind TEXT;
        UPDATE sources SET fingerprint = 'rechunk:' || fingerprint, content_hash = NULL;
        DROP TRIGGER vector_source_time;
        CREATE TRIGGER vector_source_time AFTER UPDATE OF started_at ON sources
          WHEN OLD.started_at IS NOT NEW.started_at BEGIN
          INSERT INTO vector_changes(chunk_id) SELECT id FROM chunks WHERE source = NEW.id AND vec IS NOT NULL;
        END;
        """,
    ]

    func migrate() throws {
        var version = 0
        try db.query("PRAGMA user_version") { version = Int($0.int(0)) }
        guard version <= Self.migrations.count else {
            throw Database.Failure(message: "Index schema \(version) is newer than this WorkScribe (\(Self.migrations.count))")
        }
        for step in version..<Self.migrations.count {
            try db.transaction {
                try db.execute(Self.migrations[step])
                try db.execute("PRAGMA user_version = \(step + 1)")
            }
        }
    }

    public var userVersion: Int {
        var version = 0
        try? db.query("PRAGMA user_version") { version = Int($0.int(0)) }
        return version
    }

    public func meta(_ key: String) throws -> String? {
        try db.scalar("SELECT value FROM meta WHERE key = ?", [.text(key)])
    }

    public func setMeta(_ key: String, _ value: String) throws {
        try db.run("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                   [.text(key), .text(value)])
    }

    /// The model the stored vectors came from.
    public var vectorModel: String? { try? meta("vector_model") }

    /// Adopts `modelID` for vectors. A different model's vectors can't be compared with this one's, so they are
    /// dropped and every source is marked for re-embedding (its chunks and keyword text stay searchable meanwhile).
    @discardableResult
    public func adopt(modelID: String) throws -> Bool {
        guard try meta("vector_model") != modelID else { return false }
        try db.transaction {
            try db.run("UPDATE chunks SET vec = NULL")
            try db.run("UPDATE sources SET model_id = NULL")
            try setMeta("vector_model", modelID)
        }
        invalidate()
        return true
    }

    // MARK: Sources

    public func source(ref: String) throws -> IndexedSource? {
        var out: IndexedSource?
        try db.query("""
            SELECT id, kind, ref, root, title, fingerprint, content_hash, model_id, voice_revision, state, detail
            FROM sources WHERE ref = ?
            """, [.text(ref)]) { out = Self.source($0) }
        return out
    }

    public func sources(kind: SourceKind) throws -> [IndexedSource] {
        var out: [IndexedSource] = []
        try db.query("""
            SELECT id, kind, ref, root, title, fingerprint, content_hash, model_id, voice_revision, state, detail
            FROM sources WHERE kind = ? ORDER BY id
            """, [.text(kind.rawValue)]) { out.append(Self.source($0)) }
        return out
    }

    private static func source(_ row: Statement) -> IndexedSource {
        IndexedSource(id: row.int(0), kind: SourceKind(rawValue: row.text(1) ?? "") ?? .file, ref: row.text(2) ?? "",
                      root: row.text(3), title: row.text(4), fingerprint: row.text(5) ?? "", contentHash: row.text(6),
                      modelID: row.text(7), voiceRevision: row.isNull(8) ? nil : Int(row.int(8)),
                      state: row.text(9) ?? "", detail: row.text(10))
    }

    /// Replaces everything indexed for `ref` with `chunks`, in one transaction (a crash never leaves half a source).
    /// `modelID` is the model every vector in `chunks` came from, or nil when they have none (keyword-only).
    public func replace(kind: SourceKind, ref: String, root: String? = nil, title: String?, startedAt: Date? = nil,
                        fingerprint: String, contentHash: String? = nil, modelID: String?, voiceRevision: Int? = nil,
                        state: String = "indexed", detail: String? = nil, meta: [String: String]? = nil, chunks: [Chunk]) throws {
        let source = SourceID(kind == .meeting ? .meeting : kind == .vault ? .vault : .folder, ref)
        let passages = chunks.enumerated().map { i, chunk in
            Passage(text: chunk.text ?? "", page: chunk.page, source: source,
                    anchor: chunk.anchor.isEmpty ? (chunk.anchorSegment ?? "block:\(i)") : chunk.anchor,
                    context: chunk.context, start: chunk.start, end: chunk.end, speaker: chunk.speakers.first,
                    kind: chunk.kind, modality: chunk.modality, track: chunk.track, speakerKey: chunk.speakerKeys.first,
                    segmentIDs: chunk.segmentIDs, thumbnail: chunk.thumbnail, window: chunk.window, vector: chunk.vector)
        }
        if let modelID { try adopt(modelID: modelID) }
        var revision = SourceRevision(source: source, passages: passages, title: title, root: root,
                                      startedAt: startedAt, fingerprint: fingerprint, contentHash: contentHash, voiceRevision: voiceRevision)
        revision.state = state; revision.detail = detail; revision.metadata = meta ?? [:]
        _ = try apply(revision)
    }

    /// New display names for a meeting's speakers (a voice was named): keyword text only, no re-embedding.
    public func updateSpeakers(ref: String, voiceRevision: Int?, title: String?, names: (String) -> String) throws {
        try db.transaction {
            var rows: [(Int64, [String])] = []
            try db.query("""
                SELECT c.id, c.speaker_keys FROM chunks c JOIN sources s ON s.id = c.source WHERE s.ref = ?
                """, [.text(ref)]) { rows.append(($0.int(0), Self.strings($0.text(1)))) }
            for (id, keys) in rows {
                var seen = Set<String>()
                let speakers = keys.map(names).filter { seen.insert($0).inserted }
                try db.run("UPDATE chunks SET speakers = ? WHERE id = ?", [.text(Self.json(speakers)), .int(id)])
                try db.run("UPDATE fts SET speakers = ?, title = ? WHERE rowid = ?",
                           [.text(speakers.joined(separator: ", ")), .optional(title), .int(id)])
            }
            try db.run("UPDATE sources SET voice_revision = ?, title = ? WHERE ref = ?",
                       [.optional(voiceRevision), .optional(title), .text(ref)])
        }
    }

    /// Records a newer fingerprint for unchanged content (a file touched but not edited).
    public func touch(ref: String, fingerprint: String) throws {
        try db.run("UPDATE sources SET fingerprint = ? WHERE ref = ?", [.text(fingerprint), .text(ref)])
    }

    public func remove(ref: String) throws {
        try db.transaction { try deleteRows(ref: ref) }
        invalidate()
    }

    func deleteRows(ref: String) throws {
        try db.run("DELETE FROM fts WHERE rowid IN (SELECT c.id FROM chunks c JOIN sources s ON s.id = c.source WHERE s.ref = ?)",
                   [.text(ref)])
        try db.run("DELETE FROM chunks WHERE source IN (SELECT id FROM sources WHERE ref = ?)", [.text(ref)])
        try db.run("DELETE FROM sources WHERE ref = ?", [.text(ref)])
        if hasMetaTable { try db.run("DELETE FROM source_meta WHERE ref = ?", [.text(ref)]) }
    }

    // MARK: Folders

    public func folders() throws -> [String] {
        var out: [String] = []
        try db.query("SELECT path FROM folders ORDER BY path") { out.append($0.text(0) ?? "") }
        return out
    }

    public func addFolder(_ path: String) throws {
        try db.run("INSERT OR IGNORE INTO folders(path, added_at) VALUES(?, ?)", [.text(path), .double(Date().timeIntervalSince1970)])
    }

    public func removeFolder(_ path: String) throws {
        try db.run("DELETE FROM folders WHERE path = ?", [.text(path)])
        for source in try sources(kind: .file) where source.root == path { try remove(ref: source.ref) }
    }

    public struct Counts: Sendable, Equatable { public var sources: Int; public var chunks: Int; public var vectors: Int }
    public func counts() throws -> Counts {
        var counts = Counts(sources: 0, chunks: 0, vectors: 0)
        try db.query("SELECT (SELECT COUNT(*) FROM sources), (SELECT COUNT(*) FROM chunks), (SELECT COUNT(*) FROM chunks WHERE vec IS NOT NULL)") {
            counts = Counts(sources: Int($0.int(0)), chunks: Int($0.int(1)), vectors: Int($0.int(2)))
        }
        return counts
    }

    // MARK: Search

    /// Searches by meaning (when `queryVector` from `queryModelID` matches the stored vectors) and by words.
    public func search(_ request: SearchRequest, queryVector: [Float]? = nil, queryModelID: String? = nil) throws -> SearchResults {
        let terms = SearchText.terms(request.text)
        let lookup = SearchText.isLookup(terms)
        let hinted = SearchText.kindHints(request.text)
        let semantic = queryVector != nil && queryModelID != nil && queryModelID == vectorModel

        func allowed(_ kind: ChunkKind, _ ref: String) -> Bool {
            (request.kinds?.contains(kind) ?? true) && (request.sourceRef.map { $0 == ref } ?? true)
                && (request.sourceRefs.map { $0.contains(ref) } ?? true)
        }

        // Candidate retrieval is bounded; full SQLite vectors rerank and calibrate the retained candidates.
        var meaning: [Int64: (z: Double, cosine: Float)] = [:]
        var vectorCount = 0

        // Words: FTS5 over titles, speaker names and text; coverage is the share of the query's words in the chunk.
        var coverage: [Int64: Double] = [:]
        var snippets: [Int64: String] = [:]
        var patterns = SearchText.patterns(terms, prefixLast: request.prefixLast)
        for index in terms.indices where terms[index].count >= 3 && !patterns[index].hasSuffix("*") {
            if try !isIndexed(patterns[index]) { patterns[index] += "*" }   // "grok" finds "Grok4"
        }
        if !patterns.isEmpty {
            var matched: [Int64] = []
            try db.query("""
                SELECT fts.rowid, snippet(fts, 2, '«', '»', '…', 14), c.kind, s.ref FROM fts
                JOIN chunks c ON c.id = fts.rowid JOIN sources s ON s.id = c.source
                WHERE fts MATCH ? ORDER BY bm25(fts, 3.0, 2.0, 1.0) LIMIT 2000
                """, [.text(patterns.joined(separator: " OR "))]) { row in
                let kind = ChunkKind(rawValue: row.text(2) ?? "") ?? .document, ref = row.text(3) ?? ""
                guard allowed(kind, ref) else { return }
                matched.append(row.int(0))
                if let snippet = row.text(1), snippet.contains("«") { snippets[row.int(0)] = snippet }
            }
            if !matched.isEmpty {
                let list = matched.map(String.init).joined(separator: ",")
                for pattern in patterns {
                    try db.query("SELECT rowid FROM fts WHERE fts MATCH ? AND rowid IN (\(list))", [.text(pattern)]) {
                        coverage[$0.int(0), default: 0] += 1 / Double(patterns.count)
                    }
                }
            }
        }

        if semantic, let query = queryVector.flatMap(VectorMath.normalized) {
            let result = try semanticCandidates(query, request: request, lexicalIDs: Array(coverage.keys))
            meaning = result.meaning
            vectorCount = result.population
        }

        // Fuse.
        var scored: [(id: Int64, score: Double, match: Ranking.Match)] = []
        let ids = Set(meaning.keys).union(coverage.keys)
        let kinds = try chunkKinds(Array(ids))
        for id in ids {
            let kind = kinds[id] ?? .document
            let candidate = Ranking.Candidate(z: meaning[id]?.z, cosine: meaning[id]?.cosine,
                                              coverage: coverage[id] ?? 0, kindHinted: hinted.contains(kind))
            if let result = ranking.score(candidate, vectorCount: vectorCount, lookup: lookup) {
                scored.append((id, result.score, result.match))
            }
        }
        scored.sort { $0.score > $1.score || ($0.score == $1.score && $0.id < $1.id) }

        var hits: [SearchHit] = []
        var perSource: [String: Int] = [:]
        for entry in scored {
            guard hits.count < request.limit, var hit = try hit(entry.id) else { continue }
            if let cap = request.perSource {
                guard perSource[hit.ref, default: 0] < cap else { continue }
                perSource[hit.ref, default: 0] += 1
            }
            hit.score = entry.score; hit.match = entry.match
            if hit.sourceKind == .vault { hit.meta = (try? meta(ref: hit.ref)) ?? [:] }
            hit.z = meaning[entry.id]?.z; hit.cosine = meaning[entry.id]?.cosine
            hit.snippet = snippets[entry.id] ?? hit.text.flatMap { SearchText.snippet($0, terms: terms) }
                ?? hit.text.map { SearchText.excerpt($0) }
            hits.append(hit)
        }
        return SearchResults(hits: hits, semantic: semantic, strong: Ranking.strongCount(hits.map(\.score)))
    }

    private func chunkKinds(_ ids: [Int64]) throws -> [Int64: ChunkKind] {
        guard !ids.isEmpty else { return [:] }
        var out: [Int64: ChunkKind] = [:]
        try db.query("SELECT id, kind FROM chunks WHERE id IN (\(ids.map(String.init).joined(separator: ",")))") {
            out[$0.int(0)] = ChunkKind(rawValue: $0.text(1) ?? "")
        }
        return out
    }

    private func hit(_ id: Int64) throws -> SearchHit? {
        var hit: SearchHit?
        try db.query("""
            SELECT c.id, s.kind, s.ref, s.title, c.kind, c.start_s, c.end_s, c.page, c.track, c.anchor_segment,
                   c.segment_ids, c.speakers, c.text, c.thumbnail, c.window FROM chunks c JOIN sources s ON s.id = c.source WHERE c.id = ?
            """, [.int(id)]) { row in
            hit = SearchHit(chunkID: row.int(0), sourceKind: SourceKind(rawValue: row.text(1) ?? "") ?? .file,
                            ref: row.text(2) ?? "", title: row.text(3),
                            kind: ChunkKind(rawValue: row.text(4) ?? "") ?? .document,
                            start: row.isNull(5) ? nil : row.double(5), end: row.isNull(6) ? nil : row.double(6),
                            page: row.isNull(7) ? nil : Int(row.int(7)), track: row.text(8), anchorSegment: row.text(9),
                            segmentIDs: Self.strings(row.text(10)), speakers: Self.strings(row.text(11)),
                            text: row.text(12), snippet: nil, score: 0, z: nil, cosine: nil, match: .words,
                            thumbnail: row.text(13), window: row.text(14))
        }
        return hit
    }

    private func isIndexed(_ pattern: String) throws -> Bool {
        var found = false
        try db.query("SELECT 1 FROM fts WHERE fts MATCH ? LIMIT 1", [.text(pattern)]) { _ in found = true }
        return found
    }

    /// Drop mapped pages and the ID map while idle. SQLite's change journal restores state on next use.
    public func invalidate() {
        vectorLock.lock(); defer { vectorLock.unlock() }
        compactStore = nil
    }

    static func json(_ values: [String]) -> String {
        (try? JSONSerialization.data(withJSONObject: values)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    static func strings(_ text: String?) -> [String] {
        guard let data = text?.data(using: .utf8) else { return [] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String]) ?? []
    }
}
