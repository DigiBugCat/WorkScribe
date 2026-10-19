import CryptoKit
import Foundation
import WorkScribeCore

func replayHash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
func replayWrite<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    try encoder.encode(value).write(to: url, options: .atomic)
}

/// One journal owns model outputs, exact-key vectors, timings and fail-closed miss receipts.
/// It is harness state, never part of the product's model/cache lifetime.
final class ReplayModels: @unchecked Sendable {
    struct Generation: Codable { var text: String; var stats: TextStats; var elapsed: Double }
    struct Cache: Codable {
        var model: String
        var generations: [String: [Generation]] = [:]
        var embedding: RetrievalEmbeddingCache
        var embeddingSeconds: [String: [Double]] = [:]
        var passSeconds: [String: [Double]] = [:]
        var lineSeconds: [String: [Double]]? = nil
    }
    struct Call: Codable {
        var cause: String; var job: String; var note_id: String?; var model: String
        var prompt_sha256: String; var stats: TextStats; var seconds: Double
        var evidence_ids: [String]? = nil
        var rejection: LineRejection? = nil
    }
    struct Memory: Codable { var phase: String; var footprint_bytes: UInt64 }
    private(set) var memory: [Memory] = []
    func recordMemory(_ phase: String) {
        guard real else { return }
        let value = replayFootprint()
        lock.withLock { memory.append(Memory(phase: phase, footprint_bytes: value)) }
    }
    private let lock = NSLock()
    private(set) var cache: Cache
    private(set) var calls: [Call] = []
    private(set) var seconds = 0.0
    private(set) var embedCalls = 0
    private(set) var embedHits = 0
    private(set) var misses = Set<String>()
    private var passKey = ""
    private var passStart = ContinuousClock.now
    private var passCursor: [String: Int] = [:]
    private var failure: String?
    private var generationCursor: [String: Int] = [:]
    private var embeddingCursor: [String: Int] = [:]
    var cause = ""
    let real: Bool
    let generator: (any TextModel)?
    let embedder: (any Embedder)?
    init(cache: Cache, real: Bool, generator: (any TextModel)? = nil, embedder: (any Embedder)? = nil) {
        var cache = cache
        if real { cache.generations = [:]; cache.embeddingSeconds = [:]; cache.passSeconds = [:]; cache.lineSeconds = [:] }
        self.cache = cache; self.real = real; self.generator = generator; self.embedder = embedder
    }
    func begin(_ cause: String, key: String = "") { lock.withLock {
        self.cause = cause; passKey = key; passStart = .now; seconds = 0; calls = []; embedCalls = 0; embedHits = 0
    } }
    func lineTime(_ note: String) throws -> Double {
        try lock.withLock {
            let key = passKey + "|line|" + note
            if real {
                let elapsed = (ContinuousClock.now - passStart).milliseconds / 1000
                cache.lineSeconds?[key, default: []].append(elapsed)
                return elapsed
            }
            let index = passCursor[key, default: 0]
            guard let values = cache.lineSeconds?[key], index < values.count else {
                misses.insert("line-duration/" + key)
                throw CaptureError.message("Missing line completion time")
            }
            passCursor[key] = index + 1
            return values[index]
        }
    }
    func finishPass() throws -> Double {
        try lock.withLock {
            if real {
                let elapsed = (ContinuousClock.now - passStart).milliseconds / 1000
                cache.passSeconds[passKey, default: []].append(elapsed)
                return elapsed
            }
            let index = passCursor[passKey, default: 0]
            guard let values = cache.passSeconds[passKey], index < values.count else {
                misses.insert("pass-duration/" + passKey)
                throw CaptureError.message("Missing pass duration")
            }
            passCursor[passKey] = index + 1
            return values[index]
        }
    }
    func check() throws {
        if let failure { throw CaptureError.message(failure) }
        if !misses.isEmpty { throw CaptureError.message("Replay cache misses: \(misses.count); see misses.json") }
    }
    func missed(_ key: String) { lock.withLock { _ = misses.insert(key) } }
    func generate(_ request: TextRequest) async throws -> TextGeneration {
        let template = LlamaTextEngine.template(.gemma4)
        let hash = replayHash("<bos>" + template.head + request.instruction + template.tail)
        let settings = "\(request.maxTokens)|\(request.stop ?? "")|\(request.firstLine)|\(request.cacheablePrefix ?? "")"
        let key = cache.model + "/" + hash + "/" + replayHash(settings)
        let entry: Generation
        if real, let generator {
            recordMemory("before-generation")
            let start = ContinuousClock.now
            do {
                let value = try await generator.generate(request)
                entry = Generation(text: value.text, stats: value.stats, elapsed: (ContinuousClock.now - start).milliseconds / 1000)
            } catch { lock.withLock { failure = String(describing: error) }; throw error }
            recordMemory("after-generation")
            lock.withLock { cache.generations[key, default: []].append(entry) }
        } else if let hit: Generation = lock.withLock({
            let index = generationCursor[key, default: 0]
            guard let entries = cache.generations[key], index < entries.count else { return nil }
            generationCursor[key] = index + 1
            return entries[index]
        }) { entry = hit }
        else { missed(key); throw CaptureError.message("Missing generation \(hash)") }
        lock.withLock {
            seconds += entry.elapsed
            calls.append(Call(cause: cause, job: request.instruction.hasPrefix(BriefPolicy.promptHead) ? "brief" : request.instruction.hasPrefix(NotePrompt.topicsHead) ? "topics" : request.instruction.hasPrefix(Commitments.rephraseHead) ? "actions" : "line",
                              note_id: request.noteID, model: cache.model, prompt_sha256: hash, stats: entry.stats, seconds: entry.elapsed, evidence_ids: Self.evidenceIDs(request.instruction, noteID: request.noteID)))
        }
        return TextGeneration(text: entry.text, stats: entry.stats)
    }
    func recordAttempt(_ note: String, rejection: LineRejection?) {
        lock.withLock {
            if let i = calls.lastIndex(where: { $0.note_id == note }) { calls[i].rejection = rejection }
        }
    }
    private static func evidenceIDs(_ prompt: String, noteID: String?) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"<(?:evidence|background|source) id="([^"]+)""#)
        let text = prompt as NSString
        return pattern.matches(in: prompt, range: NSRange(location: 0, length: text.length)).map {
            let id = text.substring(with: $0.range(at: 1))
            return noteID.map { id.contains(":") ? id : $0 + ":" + id } ?? id
        }
    }
    func vectors(_ values: [String], role: TextRole) async throws -> [[Float]] {
        guard case .document(title: nil) = role else {
            if case .query = role {} else { throw CaptureError.message("Replay expects exact document text with no extra title") }
            return try await vectorInputs(values.map { RetrievalText($0, query: true) }, role: role)
        }
        return try await vectorInputs(values.map { RetrievalText($0, query: false) }, role: role)
    }
    private func vectorInputs(_ inputs: [RetrievalText], role: TextRole) async throws -> [[Float]] {
        let keys = inputs.map { $0.key(modelID: cache.embedding.modelID) }
        let batch = replayHash(keys.joined(separator: "\n"))
        let started = ContinuousClock.now
        let absent = lock.withLock { cache.embedding.missing(inputs) }
        if !absent.isEmpty {
            guard real, let embedder else {
                for item in absent { missed(item.key(modelID: cache.embedding.modelID)) }
                throw CaptureError.message("Missing \(absent.count) exact-key embeddings")
            }
            // Preserve requested order; the production cache usually requests one input at a time.
            recordMemory("before-embedding")
            let vectors = try await embedder.texts(inputs.map(\.text), role: role)
            recordMemory("after-embedding")
            lock.withLock {
                for (key, vector) in zip(keys, vectors) { cache.embedding.vectors[key] = vector }
            }
        }
        return try lock.withLock {
            try cache.embedding.require(inputs)
            let elapsed: Double
            if real {
                elapsed = absent.isEmpty ? 0 : (ContinuousClock.now - started).milliseconds / 1000
                cache.embeddingSeconds[batch, default: []].append(elapsed)
            } else {
                let index = embeddingCursor[batch, default: 0]
                if let samples = cache.embeddingSeconds[batch] {
                    guard index < samples.count else {
                        misses.insert("embedding-duration/" + batch)
                        throw CaptureError.message("Missing embedding call duration")
                    }
                    elapsed = samples[index]; embeddingCursor[batch] = index + 1
                } else {
                    // A different schedule can regroup exact cached vectors without invoking a model.
                    elapsed = 0
                }
            }
            seconds += elapsed
            if elapsed > 0 { embedCalls += 1 } else { embedHits += 1 }
            return keys.map { cache.embedding.vectors[$0]! }
        }
    }
}

struct ReplayTextModel: TextModel {
    let journal: ReplayModels
    var displayName: String { journal.cache.model }
    var backend: TextBackend { .llama }
    var isAvailable: Bool { true }
    func generate(_ request: TextRequest) async throws -> TextGeneration { try await journal.generate(request) }
    func stream(_ request: TextRequest) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func prewarm(_ request: TextRequest?) async {}
    func release() async {}
}
struct ReplayEmbedder: Embedder {
    let journal: ReplayModels
    var modelID: String { journal.cache.embedding.modelID }
    var dimension: Int { journal.cache.embedding.dimension }
    var supportsAudio: Bool { false }
    func text(_ value: String, role: TextRole) async throws -> [Float] { try await texts([value], role: role)[0] }
    func texts(_ values: [String], role: TextRole) async throws -> [[Float]] { try await journal.vectors(values, role: role) }
    func audio(_ pcm16k: [Float]) async throws -> [Float] { throw EmbedderError.audioUnsupported }
}

final class ReplayEmissions: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(Enrichment, Double)] = []
    func append(_ patch: Enrichment, seconds: Double) { lock.withLock { stored.append((patch, seconds)) } }
    var values: [(Enrichment, Double)] { lock.withLock { stored } }
}
