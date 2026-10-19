import Foundation
import WorkScribeCore

/// Discrete-event adapter for the current note engine. Calls use a frozen meeting snapshot;
/// their measured/cached service times enqueue completion, while input events keep arriving.
/// Product checks are shared in CurrentNoteEngine; no gold is decoded here.
enum Replay {
    struct Row: Codable {
        var case_id: String; var note_id: String; var at: Double; var cause: String; var state: String
        var text: String; var revision: Int; var jot: String
        var available_segment_ids: [String]; var evidence: [String]; var background: [String]
    }
    struct Pass: Codable {
        var case_id: String; var at: Double; var finished_at: Double; var cause: String
        var calls: [ReplayModels.Call]; var embedding_calls: Int; var embedding_cache_hits: Int
    }
    struct Funnel: Codable {
        var case_id: String; var note_id: String; var at: Double
        var candidates: [String]; var kept: [String]; var prompt: [String]
        var attempts: [[String]]; var available_segment_ids: [String]
        var selected: [String]? = nil
        var rung: String? = nil; var holding: Bool? = nil; var answerable: Bool? = nil
    }
    struct Pair: Codable {
        var case_id: String; var note_id: String; var task: String; var segment_id: String?
        var segment_ids: [String]; var cheap: [Double]; var label: Int? = nil
        var gold_hits = 0; var gold_count = 0
        var observed_at: Double? = nil
    }
    struct IndexReceipt: Codable {
        var case_id: String
        var meeting_chunks: Int
        var meeting_vectors: Int
        var vault_chunks: Int
        var sqlite_bytes: Int
        var accelerator_bytes: Int
        var meeting_chunks_after_purge: Int
        var meeting_vectors_after_purge: Int
    }
    struct Result { var index: IndexReceipt?; var rows: [Row] = []; var passes: [Pass] = []; var funnel: [Funnel] = []; var pairs: [Pair] = [] }
    struct Event {
        var at: Double; var ordinal: Int
        enum Kind { case speech(ReplayCase.Speech), jot(ReplayCase.Jot), edit(String, String), retract([String]), stop }
        var kind: Kind
    }
    struct Completion { var at: Double; var draft: Enrichment?; var final: Bool; var cause: String }

    static func run(_ sample: ReplayCase, models: ReplayModels, config: EngineConstants, root: URL, exportPairs: Bool = false, decisionModel: (any DecisionModel)? = nil, findOnly: Bool = false) async throws -> Result {
        try sample.validate()
        var result = Result(), meeting = sample.meeting()
        let vault = try ReplayVault(sample.vault ?? [], root: root.appendingPathComponent(UUID().uuidString), models: models)
        models.recordMemory("\(sample.id):before-vault")
        try await vault.prepare()
        models.recordMemory("\(sample.id):after-vault")
        let plans = ReplayPlans()
        let enhancer = Enrich(constants: config, textModel: ReplayTextModel(journal: models), decisionModel: decisionModel,
            embeddingSource: { ReplayEmbedder(journal: models) }, indexSource: { vault.index },
            observePlan: { stage, plan in plans.record(stage, plan, seconds: models.seconds) },
            observeAttempt: { note, rejection in models.recordAttempt(note, rejection: rejection) })
        var events: [Event] = []
        func add(_ at: Double, _ kind: Event.Kind) { events.append(Event(at: at, ordinal: events.count, kind: kind)) }
        sample.speech.forEach { add($0.finalizedAt, .speech($0)) }
        for jot in sample.jots {
            add(jot.at, .jot(jot))
            for edit in jot.edits ?? [] { add(edit.at, .edit(jot.id, edit.text)) }
        }
        for retraction in sample.retractions ?? [] { add(retraction.at, .retract(retraction.segments)) }
        add(sample.stop_at, .stop)
        events.sort { $0.at == $1.at ? $0.ordinal < $1.ordinal : $0.at < $1.at }
        var cursor = 0, now = 0.0, due: Double?, lastRun: Double?, completions: [Completion] = []
        var stopped = false, dirty = false, pendingCause = "", revisions: [String: Int] = [:]
        var lastRows: [String: Row] = [:]
        var firstLinePriority = FirstLinePriority(), firstPending = false
        var lineEvidence: [String: [String]] = [:]
        func observe(_ cause: String, settled: Bool = false) {
            for note in meeting.notes ?? [] {
                let text = note.line.text ?? ""
                let state = note.line.owned == true ? "yours" : (settled ? (text.isEmpty ? "quiet" : "settled") : (text.isEmpty ? "listening" : "answered"))
                let previous = lastRows[note.id]
                if previous?.text != text && !text.isEmpty { revisions[note.id, default: 0] += 1 }
                let row = Row(case_id: sample.id, note_id: note.id, at: now, cause: cause, state: state, text: text,
                    revision: revisions[note.id, default: 0], jot: note.text, available_segment_ids: meeting.orderedSegments.map(\.id),
                    evidence: lineEvidence[note.id] ?? [],
                    background: plans.background(note.id))
                // State changes and evidence changes are observable; do not turn every speech event into a revision.
                if previous == nil || previous?.text != row.text || previous?.state != row.state || previous?.jot != row.jot || previous?.evidence != row.evidence {
                    result.rows.append(row); lastRows[note.id] = row
                }
            }
        }
        func schedule(_ cause: String) {
            dirty = true; pendingCause = cause
            if !stopped {
                let first = firstLinePriority.receive(meeting.notes ?? [])
                firstPending = firstPending || first
                if due == nil || first { due = CurrentNoteEngine.due(now: now, lastRun: lastRun, firstLine: first) }
            }
        }
        while cursor < events.count || !completions.isEmpty || due != nil {
            let inputAt = cursor < events.count ? events[cursor].at : .infinity
            let finishAt = completions.first?.at ?? .infinity
            let runAt = due ?? .infinity
            now = min(inputAt, finishAt, runAt)
            if inputAt <= finishAt && inputAt <= runAt {
                let event = events[cursor]; cursor += 1
                switch event.kind {
                case .speech(let speech):
                    meeting.segments.append(sample.segment(speech))
                    _ = try vault.index.apply(MeetingSource.revision(meeting))
                    schedule("speech:\(speech.id)")
                case .jot(let jot):
                    var note = Note(text: jot.text, createdAt: jot.at); note.id = jot.id; note.line.state = .listening
                    meeting.notes!.append(note); observe("jot"); schedule("jot:\(jot.id)")
                case .edit(let id, let text):
                    if let i = meeting.notes?.firstIndex(where: { $0.id == id }) { meeting.notes![i].editText(text, at: stopped ? nil : now) }
                    observe("edit"); schedule("edit:\(id)")
                case .retract(let ids):
                    meeting.segments.removeAll { ids.contains($0.id) }
                    _ = try vault.index.apply(MeetingSource.revision(meeting))
                    let remaining = Dictionary(Chunker.transcript(meeting).map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
                    for i in (meeting.notes ?? []).indices {
                        let texts = (meeting.notes![i].line.evidence ?? []).compactMap { remaining[$0] }
                        meeting.notes![i].line.retract(remaining: texts, jot: meeting.notes![i].text)
                    }
                    try vault.index.saveLines(meeting)
                    observe("retraction")
                    schedule("retraction")
                case .stop:
                    stopped = true; due = nil; dirty = true; pendingCause = "stop"
                    meeting.status = "complete"; meeting.endedAt = Date(timeIntervalSince1970: now)
                    _ = try vault.index.apply(MeetingSource.revision(meeting))
                    // Keep the current line; Stop widens the evidence window after it drains.
                    if completions.isEmpty { due = now }
                }
            } else if finishAt <= runAt, let finished = completions.first {
                completions.removeFirst()
                if let draft = finished.draft {
                    let eligible = Set(draft.plan.targets.filter { target in
                        (meeting.notes ?? []).contains { $0.id == target.note.id && $0.text == target.note.text && $0.queryRevision == target.note.queryRevision && $0.line.revision == target.note.line.revision && $0.line.owned != true && $0.fromAnswer == nil }
                    }.map { $0.note.id })
                    if CurrentNoteEngine.apply(draft, to: &meeting, final: finished.final, at: Date(timeIntervalSince1970: now)) { dirty = true }
                    try vault.index.saveLines(meeting)
                    // Evidence belongs to the frozen call snapshot, not to later speech.
                    for target in draft.plan.targets where eligible.contains(target.note.id) {
                        guard case .line = draft.outcomes[target.note.id] else { continue }
                        lineEvidence[target.note.id] = Array(Set(draft.plan.evidence(for: target).flatMap { $0.chunk.segmentIDs })).sorted()
                    }
                }
                if finished.final {
                    for i in (meeting.notes ?? []).indices { meeting.notes![i].line.settle() }
                    try vault.index.saveLines(meeting)
                }
                observe(finished.cause, settled: finished.final)
                if finished.final { dirty = false; due = nil }
                else if stopped && completions.isEmpty { due = now }
                else if dirty && completions.isEmpty && due == nil { due = CurrentNoteEngine.due(now: now, lastRun: lastRun, firstLine: firstPending) }
            } else {
                due = nil
                // A timer can fire while the prior pass is still running. The app's run guard
                // consumes that timer, keeps dirty, and schedules again when the pass returns.
                if !completions.isEmpty { continue }
                guard dirty, !(meeting.notes ?? []).isEmpty else { dirty = false; continue }
                firstPending = false
                dirty = false; let previousRun = lastRun; lastRun = now
                let cause = pendingCause, snapshot = meeting
                let identity = sample.id + "|" + cause + "|" + snapshot.segments.map { $0.id + $0.text }.joined(separator: "|") + "|" + (snapshot.notes ?? []).map { $0.id + $0.text + ($0.line.text ?? "") }.joined(separator: "|")
                models.begin(cause, key: replayHash(identity)); plans.clear()
                let draft: Enrichment?
                let emissions = ReplayEmissions()
                if findOnly {
                    _ = try await enhancer.selection(snapshot, incremental: false)
                    draft = nil
                } else { draft = try await enhancer.enhance(snapshot, incremental: !stopped) { patch in
                    if !patch.outcomes.isEmpty { emissions.append(patch, seconds: (try? models.lineTime(patch.plan.targets[0].note.id)) ?? 0) }
                } }
                if draft == nil { lastRun = previousRun }
                if let draft, draft.plan.targets.contains(where: { draft.outcomes[$0.note.id] == nil }) { dirty = true }
                try models.check()
                let end = now + (findOnly ? 0 : try models.finishPass())
                result.passes.append(Pass(case_id: sample.id, at: now, finished_at: end, cause: cause,
                                          calls: models.calls, embedding_calls: models.embedCalls, embedding_cache_hits: models.embedHits))
                for entry in plans.funnel(caseID: sample.id, at: now, calls: models.calls, available: snapshot.orderedSegments.map(\.id)) { result.funnel.append(entry) }
                if exportPairs && (!findOnly || cause.hasPrefix("jot:") || stopped) { result.pairs += try plans.pairs(caseID: sample.id, models: models, chunks: Chunker.transcript(snapshot), at: now) }
                completions = emissions.values.map { Completion(at: min(end, now + $0.1), draft: $0.0, final: false, cause: cause) }
                completions.append(Completion(at: end, draft: nil, final: stopped, cause: cause))
            }
        }
        if !findOnly && !(meeting.notes ?? []).isEmpty {
            models.begin("after-stop", key: replayHash(sample.id + "|after-stop|" + (meeting.notes ?? []).map { $0.text + ($0.line.text ?? "") }.joined(separator: "|")))
            _ = try await enhancer.synthesis.afterStop(meeting)
            try models.check()
            let duration = try models.finishPass()
            result.passes.append(Pass(case_id: sample.id, at: now, finished_at: now + duration, cause: "after-stop",
                                      calls: models.calls, embedding_calls: models.embedCalls, embedding_cache_hits: models.embedHits))
        }
        let source = SourceID(.meeting, meeting.id)
        let chunks = try vault.index.sourceChunks(source)
        let counts = try vault.index.counts()
        let vectors = try vault.index.vectorStats()
        try vault.index.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        let bytes = (try FileManager.default.attributesOfItem(atPath: vault.index.url.path)[.size] as? NSNumber)?.intValue ?? 0
        try vault.index.purge(source)
        let remaining = try vault.index.sourceChunks(source)
        result.index = IndexReceipt(case_id: sample.id, meeting_chunks: chunks.count,
            meeting_vectors: chunks.filter { $0.vector != nil }.count, vault_chunks: counts.chunks - chunks.count,
            sqlite_bytes: bytes, accelerator_bytes: vectors.mappedBytes,
            meeting_chunks_after_purge: remaining.count, meeting_vectors_after_purge: remaining.filter { $0.vector != nil }.count)
        return result
    }

    static func cli(_ args: [String]) async throws {
        func value(_ key: String, fallback: String? = nil) throws -> String {
            if let i = args.firstIndex(of: key), i + 1 < args.count, !args[i + 1].hasPrefix("--") { return args[i + 1] }
            if let fallback { return fallback }; throw CaptureError.message("Missing \(key)")
        }
        let input = URL(fileURLWithPath: try value("--replay")), out = URL(fileURLWithPath: try value("--out"))
        let mode = try value("--models", fallback: "cached")
        guard ["real", "cached"].contains(mode) else { throw CaptureError.message("--models must be cached or real") }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let samples = try Data(contentsOf: input).split(separator: 10).map { try JSONDecoder().decode(ReplayCase.self, from: Data($0)) }
        guard !samples.isEmpty, Set(samples.map(\.id)).count == samples.count else { throw CaptureError.message("Duplicate or empty replay cases") }
        for sample in samples { try sample.validate() }
        if args.contains("--audio") {
            guard mode == "real" else { throw CaptureError.message("--audio requires --models real") }
            let path = try value("--audio-fixture", fallback: samples.compactMap(\.audio).first)
            guard let duration = Double(try value("--duration", fallback: "3600")), duration.isFinite, duration > 0 else { throw CaptureError.message("--duration must be positive seconds") }
            try await ReplayAudio.run(fixture: URL(fileURLWithPath: path), output: out,
                                      duration: duration)
            return
        }
        let cacheURL = URL(fileURLWithPath: try value("--cache", fallback: out.appendingPathComponent("models.json").path))
        guard input.resolvingSymlinksInPath() != cacheURL.resolvingSymlinksInPath() else { throw CaptureError.message("Cache must not overwrite replay cases") }
        let native = mode == "real" ? try GemmaEvaluation.model(runtime: "llama") : nil
        let embedding = mode == "real" ? CoreMLEmbedder.bundled() : nil
        var cache: ReplayModels.Cache
        if FileManager.default.fileExists(atPath: cacheURL.path) { cache = try JSONDecoder().decode(ReplayModels.Cache.self, from: Data(contentsOf: cacheURL)) }
        else {
            guard let embedding else { throw CaptureError.message("Cached replay needs --cache from a real run") }
            cache = .init(model: "gemma4-e4b@" + GemmaEvaluation.ggufSHA256, embedding: RetrievalEmbeddingCache(modelID: embedding.modelID, dimension: embedding.dimension))
        }
        guard cache.model == "gemma4-e4b@" + GemmaEvaluation.ggufSHA256 else { throw CaptureError.message("Generator cache/model identity mismatch") }
        if let embedding, cache.embedding.modelID != embedding.modelID || cache.embedding.dimension != embedding.dimension { throw CaptureError.message("Embedding cache/model identity mismatch") }
        if args.contains("--embed-cache") {
            let imported = try JSONDecoder().decode(RetrievalEmbeddingCache.self, from: Data(contentsOf: URL(fileURLWithPath: try value("--embed-cache"))))
            guard imported.modelID == cache.embedding.modelID, imported.dimension == cache.embedding.dimension else { throw CaptureError.message("Imported embedding identity mismatch") }
            cache.embedding.vectors.merge(imported.vectors) { old, _ in old }
        }
        let models = ReplayModels(cache: cache, real: mode == "real", generator: native, embedder: embedding)
        let config = args.contains("--arm") ? try EngineConstants.load(URL(fileURLWithPath: value("--arm"))) : EngineConstants()
        let selected = args.contains("--case") ? samples.filter { $0.id == (try? value("--case")) } : samples
        guard !selected.isEmpty else { throw CaptureError.message("No matching cases") }
        var receipts: [IndexReceipt] = []
        var rows: [Row] = [], passes: [Pass] = [], funnel: [Funnel] = [], pairs: [Pair] = []
        do {
            for sample in selected {
                fputs("Replay \(sample.id) (\(mode))\n", stderr)
                let result = try await run(sample, models: models, config: config, root: out.appendingPathComponent("scratch-\(sample.id)"), exportPairs: args.contains("--export-pairs"), findOnly: args.contains("--find-only"))
                rows += result.rows; passes += result.passes; funnel += result.funnel; pairs += result.pairs
                if let receipt = result.index { receipts.append(receipt) }
                if mode == "real" {
                    try replayWrite(models.cache, to: cacheURL)
                    try replayWrite(models.memory, to: out.appendingPathComponent("memory.json"))
                }
            }
            func jsonl<T: Encodable>(_ rows: [T], _ name: String) throws {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                var bytes = Data(); for row in rows { bytes.append(try encoder.encode(row)); bytes.append(10) }
                try bytes.write(to: out.appendingPathComponent(name), options: .atomic)
            }
            try jsonl(receipts, "index.jsonl")
            try jsonl(rows, "timeline.jsonl"); try jsonl(passes, "calls.jsonl"); try jsonl(funnel, "funnel.jsonl")
            if args.contains("--export-pairs") {
                struct GoldCase: Decodable { struct Gold: Decodable { var abstain: Bool; var evidence: [String] }; var id: String; var gold: [String: Gold] }
                let labels = try Data(contentsOf: input).split(separator: 10).map { try JSONDecoder().decode(GoldCase.self, from: Data($0)) }
                let cases = Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0.gold) })
                for i in pairs.indices {
                    guard let gold = cases[pairs[i].case_id]?[pairs[i].note_id] else { throw CaptureError.message("Missing pair label") }
                    let hits = Set(gold.evidence).intersection(pairs[i].segment_ids).count
                    pairs[i].label = pairs[i].task == "answerability" ? (gold.abstain || hits == 0 ? 0 : 1) : (hits > 0 ? 1 : 0)
                    pairs[i].gold_hits = hits; pairs[i].gold_count = gold.evidence.count
                }
                // Same candidate can recur on several passes. Keep one example per feature vector.
                var seen = Set<Data>(); let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let unique = try pairs.filter { seen.insert(try encoder.encode($0)).inserted }
                try jsonl(unique, "pairs.jsonl")
            }
            try replayWrite(config, to: out.appendingPathComponent("arm.json"))
            struct Manifest: Encodable { var protocolVersion = "replay-v1"; var models: String; var generator: String; var embedding: String; var casesSHA256: String; var cases: [String]; var selectionOnly: Bool; var adapter = "shared Find/Decide and scheduler; settle before optional after-stop synthesis" }
            try replayWrite(Manifest(models: mode, generator: models.cache.model, embedding: models.cache.embedding.modelID,
                casesSHA256: replayHash(String(decoding: Data(contentsOf: input), as: UTF8.self)), cases: selected.map(\.id), selectionOnly: args.contains("--find-only")), to: out.appendingPathComponent("manifest.json"))
        } catch {
            try replayWrite(models.misses.sorted(), to: out.appendingPathComponent("misses.json"))
            if mode == "real" { try replayWrite(models.cache, to: cacheURL) }
            await native?.release(); throw error
        }
        if args.contains("--find-only") { return }
        let reporter = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/replay.py")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", reporter.path, "report", input.path, out.path, "--packets"]
        if args.contains("--case") { process.arguments! += ["--case", try value("--case")] }
        if args.contains("--judgments") { process.arguments! += ["--judgments", try value("--judgments")] }
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CaptureError.message("Replay report failed (\(process.terminationStatus))") }
        await native?.release()
        models.recordMemory("after-generator-release")
        if mode == "real" { try replayWrite(models.memory, to: out.appendingPathComponent("memory.json")) }
    }
}

/// Fixture vault uses the same passage chunker, index and background selector as the app.
final class ReplayVault: @unchecked Sendable {
    let root: URL; let index: SearchIndex; let models: ReplayModels; let notes: [ReplayCase.Vault]
    init(_ notes: [ReplayCase.Vault], root: URL, models: ReplayModels) throws {
        self.root = root; self.models = models; self.notes = notes
        index = try SearchIndex(url: root.appendingPathComponent("index.sqlite"))
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func prepare() async throws {
        guard !notes.isEmpty else { return }
        try index.adopt(modelID: models.cache.embedding.modelID)
        for note in notes {
            let source = SourceID(.vault, note.id)
            _ = try index.apply(SourceRevision(source: source,
                passages: MarkdownSource.passages(note.markdown, title: note.title, source: source),
                title: note.title, fingerprint: "fixture"))
            try await index.embedMissing(source, using: ReplayEmbedder(journal: models))
        }
    }

}

/// Metadata-only observer; the product never reads it or changes selection for it.
final class ReplayPlans: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [String: (EnrichmentBatch, Double)] = [:]
    private var backgrounds: [String: [String]] = [:]
    func recordBackground(_ note: String, ids: [String]) { lock.withLock { backgrounds[note] = ids } }
    func background(_ note: String) -> [String] { lock.withLock { backgrounds[note] ?? [] } }
    func clear() { lock.withLock { stages = [:] } }
    func record(_ stage: String, _ plan: EnrichmentBatch, seconds: Double) { lock.withLock {
        stages[stage] = (plan, seconds)
        if stage == "budgeted" { for target in plan.targets { backgrounds[target.note.id] = target.background.map(\.id) } }
    } }
    func funnel(caseID: String, at: Double, calls: [ReplayModels.Call], available: [String]) -> [Replay.Funnel] {
        lock.withLock {
            guard let first = stages["candidates"], let kept = stages["kept"] else { return [] }
            func ids(_ plan: EnrichmentBatch, _ id: String) -> [String] {
                guard let target = plan.targets.first(where: { $0.note.id == id }) else { return [] }
                return Array(Set(plan.evidence(for: target).flatMap { $0.chunk.segmentIDs })).sorted()
            }
            return first.0.targets.map { target in
                let attempts = calls.filter { $0.job == "line" && $0.note_id == target.note.id }.map { call in
                    Array(Set(kept.0.excerpts.filter { (call.evidence_ids ?? []).contains($0.id) }.flatMap { $0.chunk.segmentIDs })).sorted()
                }
                return Replay.Funnel(case_id: caseID, note_id: target.note.id, at: at + first.1,
                    candidates: ids(first.0, target.note.id), kept: ids(kept.0, target.note.id), prompt: attempts.first ?? [], attempts: attempts, available_segment_ids: available, selected: stages["selected"].map { ids($0.0, target.note.id) }, rung: (stages["budgeted"]?.0 ?? kept.0).findings[target.note.id]?.rung?.rawValue, holding: kept.0.findings[target.note.id]?.holding, answerable: (stages["budgeted"]?.0 ?? kept.0).findings[target.note.id]?.answerable)
            }
        }
    }
    func pairs(caseID: String, models: ReplayModels, chunks: [TranscriptChunk], at: Double = 0) throws -> [Replay.Pair] {
        try lock.withLock {
            guard let plan = stages["candidates"]?.0, let budget = stages["budgeted"]?.0 else { return [] }
            let cache = models.cache.embedding, ordered = chunks.sorted { $0.start < $1.start }
            let changes = Dictionary(ordered.enumerated().map { index, chunk in
                (chunk.id, index > 0 && ordered[index - 1].speaker != chunk.speaker)
            }, uniquingKeysWith: { first, _ in first })
            var pairs: [Replay.Pair] = []
            for target in plan.targets {
                let qkey = RetrievalText(target.note.matchingText, query: true).key(modelID: cache.modelID)
                guard let q = cache.vectors[qkey] else {
                    models.missed(qkey); throw CaptureError.message("Missing pair query vector: \(qkey)")
                }
                func features(_ evidence: [TranscriptChunk]) throws -> [[Double]] {
                    try evidence.map { chunk in
                        let key = RetrievalText(chunk.text, query: false).key(modelID: cache.modelID)
                        guard let d = cache.vectors[key] else {
                            models.missed(key); throw CaptureError.message("Missing pair document vector: \(key)")
                        }
                        return EmbeddingDecisionModel.contextualFeatures(jot: target.note, chunk: chunk, cosine: Double(VectorMath.dot(q, d)), speakerChanged: changes[chunk.id] ?? false, neighbors: ordered)
                    }
                }
                let original = Dictionary(chunks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let candidates = plan.evidence(for: target).compactMap { original[$0.chunk.id] }
                for (chunk, f) in zip(candidates, try features(candidates)) {
                    pairs.append(.init(case_id: caseID, note_id: target.note.id, task: "relevance", segment_id: chunk.id, segment_ids: chunk.segmentIDs, cheap: f))
                }
                guard let bounded = budget.targets.first(where: { $0.note.id == target.note.id }) else { continue }
                let evidence = budget.evidence(for: bounded).compactMap { original[$0.chunk.id] }, f = try features(evidence)
                if !f.isEmpty {
                    let cosines = f.map { $0[0] }.sorted(by: >)
                    let query = EmbeddingDecisionModel.tokens(target.note.matchingText)
                    let words = evidence.reduce(into: Set<String>()) { $0.formUnion(EmbeddingDecisionModel.tokens($1.text)) }
                    let answer = [cosines[0], cosines.prefix(3).reduce(0,+)/Double(min(3,cosines.count)), f.map { $0[3] }.max()!, Double(query.intersection(words).count)/Double(max(1,query.count)), f.map { $0[4] }.max()!, f.map { $0[1] }.min()!, log1p(Double(f.count))]
                    pairs.append(.init(case_id: caseID, note_id: target.note.id, task: "answerability", segment_ids: Array(Set(evidence.flatMap(\.segmentIDs))).sorted(), cheap: answer))
                }
            }
            for i in pairs.indices { pairs[i].observed_at = at }
            return pairs
        }
    }

}
