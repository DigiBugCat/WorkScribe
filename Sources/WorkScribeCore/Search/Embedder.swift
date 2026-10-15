import Accelerate
import Foundation

/// How a text is embedded. EmbeddingGemma 2 was trained with different prefixes for the two sides of retrieval:
/// `task: search result | query: …` for what someone asks and `title: … | text: …` for what gets found.
public enum TextRole: Sendable, Hashable {
    case query
    case document(title: String?)
}

/// A content embedder: text and short audio windows into one vector space, so a typed query can find either.
///
/// Used by semantic search (`SearchIndex`, `MeetingIndexer`, `FolderIndexer`) and meant for any other "match by
/// meaning" feature (linking shorthand notes to transcript moments, question cards). It is not for speaker identity:
/// voices stay on WeSpeaker (`VoiceMatching`). Vectors are L2-normalized, so a dot product is the cosine.
public protocol Embedder: Sendable {
    /// Identifies everything that changes the vectors: model revision, dimension, preprocessing. A stored index built
    /// with another ID is re-embedded.
    var modelID: String { get }
    var dimension: Int { get }
    /// Whether `audio(_:)` works (the audio encoder is installed).
    var supportsAudio: Bool { get }
    var supportsImages: Bool { get }
    func image(_ url: URL) async throws -> [Float]
    func text(_ value: String, role: TextRole) async throws -> [Float]
    /// Many texts with one role, in order. Implementations batch them (Core ML packs short texts eight to a call).
    func texts(_ values: [String], role: TextRole) async throws -> [[Float]]
    /// One nonempty mono 16 kHz window of at most `Embedders.audioWindowSamples` samples.
    func audio(_ pcm16k: [Float]) async throws -> [Float]
}

public extension Embedder {
    var supportsImages: Bool { false }
    func image(_ url: URL) async throws -> [Float] { throw EmbedderError.imageUnsupported }
    func texts(_ values: [String], role: TextRole) async throws -> [[Float]] {
        var out: [[Float]] = []
        for value in values { out.append(try await text(value, role: role)) }
        return out
    }
}

public enum EmbedderError: Error, CustomStringConvertible {
    case unavailable(String)
    case audioUnsupported
    case imageUnsupported
    case badVector(String)
    public var description: String {
        switch self {
        case .unavailable(let why): "Embedding model unavailable: \(why)"
        case .imageUnsupported: "The image embedding model is not installed"
        case .audioUnsupported: "The audio embedding model is not installed"
        case .badVector(let why): "Bad embedding: \(why)"
        }
    }
}

public enum Embedders {
    public static let audioSampleRate = 16_000
    /// EmbeddingGemma 2's audio input: 10 s at 16 kHz.
    public static let audioWindowSamples = 160_000
}

/// Vector arithmetic on Float32 vectors (Accelerate).
public enum VectorMath {
    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count)
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }

    /// The vector scaled to unit length; nil when it is empty, zero, or not finite.
    public static func normalized(_ vector: [Float]) -> [Float]? {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
        let norm = dot(vector, vector).squareRoot()
        guard norm > 0 else { return nil }
        var scale = 1 / norm, out = [Float](repeating: 0, count: vector.count)
        vDSP_vsmul(vector, 1, &scale, &out, 1, vDSP_Length(vector.count))
        return out
    }

    /// `rows` (row-major, `count` × `dimension`) times `query`: every row's dot product with the query.
    public static func scores(rows: UnsafePointer<Float>, count: Int, dimension: Int, query: [Float]) -> [Float] {
        var scores = [Float](repeating: 0, count: count)
        guard count > 0 else { return scores }
        vDSP_mmul(rows, 1, query, 1, &scores, 1, vDSP_Length(count), 1, vDSP_Length(dimension))
        return scores
    }

    /// Indices of the `k` highest-scoring of `candidates` against `query`, best first, with their cosines. For small
    /// in-memory sets (a live meeting's chunks for note matching), where an index would be overkill.
    public static func top(_ k: Int, of candidates: [[Float]], for query: [Float], minimum: Float = -1) -> [(index: Int, score: Float)] {
        let scored = candidates.enumerated().compactMap { index, vector -> (Int, Float)? in
            guard vector.count == query.count else { return nil }
            let score = dot(vector, query)
            return score >= minimum ? (index, score) : nil
        }
        return Array(scored.sorted { $0.1 > $1.1 }.prefix(k)).map { (index: $0.0, score: $0.1) }
    }

    static func blob(_ vector: [Float]) -> Data { vector.withUnsafeBufferPointer { Data(buffer: $0) } }
}
