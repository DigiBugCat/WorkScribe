import Foundation
import WorkScribeCore

struct Enrichment: Sendable {
    var plan: EnrichmentBatch
    var model: String? = nil
    var durationMs: Int? = nil
    var location: String? = nil
    var sceneSources: [String: [TraceSource]] = [:]
    var outcomes: [String: LineOutcome] = [:]
    var bases: [String: String] = [:]
}
protocol Enriching: Sendable {
    func enhance(_ meeting: Meeting, incremental: Bool) async throws -> Enrichment?
    func enhance(_ meeting: Meeting, incremental: Bool, didProduce: @escaping @Sendable (Enrichment) async -> Void) async throws -> Enrichment?
    /// The last search for this meeting could see its transcript, so finding nothing means nothing was said.
    func searched(_ meetingID: String) async -> Bool
}
extension Enriching {
    func searched(_ meetingID: String) async -> Bool { true }
    func enhance(_ meeting: Meeting, incremental: Bool, didProduce: @escaping @Sendable (Enrichment) async -> Void) async throws -> Enrichment? {
        let result = try await enhance(meeting, incremental: incremental)
        if let result { await didProduce(result) }
        return result
    }
}

actor Enrich: Enriching {
    private let observeAttempt: (@Sendable (String, LineRejection?) -> Void)?
    private let observePlan: (@Sendable (String, EnrichmentBatch) -> Void)?
    private let indexSource: @Sendable () async -> SearchIndex?
    private var localIndex: SearchIndex?
    private var queryVectors: [String: [Float]] = [:]
    private var covered: [String: Bool] = [:]
    func searched(_ meetingID: String) -> Bool { covered[meetingID] ?? false }
    private var queryModel: String?
    private let embeddingSource: @Sendable () async -> (any Embedder)?
    private let decisionModel: (any DecisionModel)?
    private let constants: EngineConstants
    private let modelOverride: (any TextModel)?
    static let standaloneEmbedder = CoreMLEmbedder.bundled(idleSeconds: 120)
    nonisolated(unsafe) static var embedderSource: @Sendable () async -> (any Embedder)? = { standaloneEmbedder }
    static func warmEmbedder() { Task.detached(priority: .utility) { _ = try? await embedderSource()?.text("warm up", role: .query) } }
    static func prewarmLineModel() {
        Task.detached(priority: .utility) {
            let model = TextModels.model(for: .line)
            guard model.isAvailable else { return }
            await model.prewarm(TextRequest(LinePrompt.rules + "<note>warm up</note>\n", cacheablePrefix: LinePrompt.rules, maxTokens: 1))
        }
    }
    init(constants: EngineConstants = EngineConstants(), textModel: (any TextModel)? = nil,
         decisionModel: (any DecisionModel)? = nil, embeddingSource: (@Sendable () async -> (any Embedder)?)? = nil,
         indexSource: (@Sendable () async -> SearchIndex?)? = nil,
         observePlan: (@Sendable (String, EnrichmentBatch) -> Void)? = nil,
         observeAttempt: (@Sendable (String, LineRejection?) -> Void)? = nil) {
        self.constants = constants; self.modelOverride = textModel; self.decisionModel = decisionModel
        self.observePlan = observePlan; self.observeAttempt = observeAttempt
        self.indexSource = indexSource ?? { nil }; self.embeddingSource = embeddingSource ?? { await Enrich.embedderSource() }
    }
    func selection(_ meeting: Meeting, incremental: Bool) async throws -> EnrichmentBatch {
        if (meeting.notes ?? []).allSatisfy({ $0.isImage || $0.surface != nil || $0.matchingText.isEmpty }) {
            var batch = EnrichmentBatch()
            batch.targets = (meeting.notes ?? []).filter { $0.surface == nil && !$0.imageEvidence.isEmpty && $0.line.owned != true }.map {
                LineRequest(note: $0, refs: [], fresh: [], previous: $0.line.text)
            }
            covered[meeting.id] = true
            return batch
        }
        guard let embedder = await embeddingSource() else { throw CaptureError.message("AI lines need EmbeddingGemma 2. Run WorkScribe --doctor.") }
        let index: SearchIndex
        if let supplied = await indexSource() { index = supplied }
        else {
            if localIndex == nil { localIndex = try SearchIndex() }
            index = localIndex!
            _ = try index.apply(MeetingSource.revision(meeting))
        }
        try index.adopt(modelID: embedder.modelID)
        try await index.embedMissing(SourceID(.meeting, meeting.id), using: embedder)
        if queryModel != embedder.modelID { queryVectors = [:]; queryModel = embedder.modelID }
        for note in meeting.notes ?? [] where !note.isImage && note.surface == nil && !note.matchingText.isEmpty && queryVectors[note.matchingText] == nil {
            queryVectors[note.matchingText] = try await embedder.text(note.matchingText, role: .query)
        }
        // Vault vectors are fetched lazily only after the meeting ladder fails.
        let chunks = try index.sourceChunks(SourceID(.meeting, meeting.id)).filter { $0.vector != nil && $0.modality == .text }
        // Just after launch the shared index may not hold this meeting yet: an empty search proves nothing.
        covered[meeting.id] = !chunks.isEmpty || meeting.segments.isEmpty
        let vectors = IndexVectors(modelID: embedder.modelID, queries: queryVectors, chunks: chunks)
        let decision = try decisionModel ?? EmbeddingDecisionModel.bundled(cache: vectors, chunks: chunks.map(\.transcript))
        // A long silent stretch can revisit Find many times before the next model await.
        return try autoreleasepool {
            try FindNotes(constants: constants, index: index, vectors: vectors, decision: decision, chunks: chunks)
                .select(meeting, incremental: incremental, observe: observePlan)
        }
    }

    func enhance(_ meeting: Meeting, incremental: Bool) async throws -> Enrichment? {
        try await enhance(meeting, incremental: incremental, didProduce: { _ in })
    }
    func enhance(_ meeting: Meeting, incremental: Bool, didProduce: @escaping @Sendable (Enrichment) async -> Void) async throws -> Enrichment? {
        var plan = try await selection(meeting, incremental: incremental)
        let selected = plan
        plan.targets.removeAll { target in
            (target.refs.isEmpty && target.note.imageEvidence.isEmpty) ||
            (!target.note.lineNeedsEvidence && target.fresh.isEmpty) ||
            target.note.line.basis == Self.basis(target, plan: selected)
        }
        guard !plan.targets.isEmpty else { return nil }
        let model = modelOverride ?? TextModels.model(for: .line)
        guard model.isAvailable else { throw CaptureError.message("AI lines need the Gemma model · run WorkScribe --doctor") }
        var result = Enrichment(plan: plan, model: model.displayName, location: "On this Mac")
        await didProduce(result)
        let targets = plan.targets.sorted(by: {
            if ($0.previous == nil) != ($1.previous == nil) { return $0.previous == nil }
            return ($0.note.createdAt ?? 0) > ($1.note.createdAt ?? 0)
        })
        for target in incremental ? Array(targets.prefix(1)) : targets {
            try Task.checkCancellation()
            let evidence = plan.evidence(for: target)
            let basis = Self.basis(target, plan: plan)
            var outcome: LineOutcome = .quiet(.modelError)
            var correction: LineRejection?
            // A short answer with a concrete fact is kept in reserve: the retry asks for a fuller line, which is
            // usually richer, and the short one is used only if the model gives nothing longer.
            var short: LineOutcome?
            for attempt in 0..<2 {
                do {
                    let generated = try await model.generate(TextRequest(LinePrompt.build(target, excerpts: evidence, background: target.background, correction: correction),
                        cacheablePrefix: LinePrompt.rules, maxTokens: EngineConstants.lineTokens, stop: NotePrompt.endMarker, noteID: target.note.id))
                    outcome = LineCheck.accept(generated.text, request: target, evidence: evidence)
                    if short == nil, outcome == .quiet(.tooShort), case .line = LineCheck.accept(generated.text, request: target, evidence: evidence, allowShort: true) {
                        short = LineCheck.accept(generated.text, request: target, evidence: evidence, allowShort: true)
                    }
                    result.durationMs = (result.durationMs ?? 0) + Int(generated.stats.totalMs)
                } catch is CancellationError { throw CancellationError() }
                catch { outcome = .quiet(.modelError) }
                if case .quiet(let reason) = outcome {
                    observeAttempt?(target.note.id, reason)
                    guard attempt == 0, reason.correction != nil else { break }
                    correction = reason
                } else { observeAttempt?(target.note.id, nil); break }
            }
            if case .quiet = outcome, let short { outcome = short }
            result.outcomes[target.note.id] = outcome; result.bases[target.note.id] = basis
            result.sceneSources[target.note.id] = target.background.map {
                TraceSource(kind: "background", title: $0.title, text: $0.text,
                    link: WorkScribeLink.file(path: $0.id, page: nil, seconds: nil).url.absoluteString)
            }
            var patch = result
            patch.plan.targets = [target]
            patch.outcomes = [target.note.id: outcome]
            patch.bases = [target.note.id: basis]
            await didProduce(patch)
        }
        return result
    }
    static func basis(_ target: LineRequest, plan: EnrichmentBatch) -> String {
        Chunker.hash(target.note.text + "|" + plan.evidence(for: target).map { $0.chunk.id }.joined(separator: "|") + "|" + target.note.imageEvidence)
    }
    nonisolated var synthesis: MeetingSynthesis { MeetingSynthesis(model: modelOverride ?? TextModels.model(for: .brief)) }
}
