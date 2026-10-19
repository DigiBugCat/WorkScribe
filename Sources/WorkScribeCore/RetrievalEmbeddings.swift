import CryptoKit
import Foundation

/// Exact input identity includes the embedding role: the same text has different query/document vectors.
public struct RetrievalText: Codable, Hashable, Sendable {
    public var text: String
    public var query: Bool
    public init(_ text: String, query: Bool) { self.text = text; self.query = query }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.query == rhs.query && lhs.text.utf8.elementsEqual(rhs.text.utf8)
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(query); hasher.combine(Data(text.utf8))
    }
    public func key(modelID: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return modelID + (query ? "/query/" : "/document/") + digest
    }
}

public struct RetrievalEmbeddingCache: Codable, Sendable {
    public var version = 1
    public var modelID: String
    public var dimension: Int
    public var vectors: [String: [Float]] = [:]
    public init(modelID: String, dimension: Int) { self.modelID = modelID; self.dimension = dimension }
    public func missing(_ texts: [RetrievalText]) -> [RetrievalText] {
        Array(Set(texts)).filter { vectors[$0.key(modelID: modelID)] == nil }
            .sorted { ($0.query ? "q" : "d") + $0.text < ($1.query ? "q" : "d") + $1.text }
    }
    public func require(_ texts: [RetrievalText]) throws {
        let missing = missing(texts)
        guard missing.isEmpty else { throw CacheError.missing(missing) }
        guard version == 1, dimension > 0 else { throw CacheError.invalid("unsupported version or dimension") }
        for text in Set(texts) {
            guard let value = vectors[text.key(modelID: modelID)], value.count == dimension,
                  value.allSatisfy(\.isFinite), VectorMath.normalized(value) != nil else {
                throw CacheError.invalid("invalid vector for \(text.text)")
            }
        }
    }
    public enum CacheError: Error, CustomStringConvertible {
        case missing([RetrievalText]), invalid(String)
        public var description: String {
            switch self {
            case .missing(let texts):
                let data = try! JSONEncoder().encode(texts)
                return "Embedding cache miss (\(texts.count) inputs); refill these exact texts:\n" + String(decoding: data, as: UTF8.self)
            case .invalid(let message): return "Embedding cache: \(message)"
            }
        }
    }

}

extension RetrievalEmbeddingCache: RetrievalVectorSource {
    public func vector(_ text: RetrievalText) -> [Float]? { vectors[text.key(modelID: modelID)] }
}
