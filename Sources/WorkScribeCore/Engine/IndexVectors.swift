import Foundation

/// Read-only vectors for a single selection. Document storage belongs to Index; only user queries are cached.
public protocol RetrievalVectorSource: Sendable {
    var modelID: String { get }
    func vector(_ text: RetrievalText) -> [Float]?
    func require(_ texts: [RetrievalText]) throws
}
public struct IndexVectors: RetrievalVectorSource {
    public let modelID: String
    private let queries: [String: [Float]]
    private let documents: [String: [Float]]
    public init(modelID: String, queries: [String: [Float]], chunks: [Chunk]) {
        self.modelID = modelID; self.queries = queries
        self.documents = Dictionary(chunks.compactMap { chunk in chunk.vector.map { (chunk.text ?? "", $0) } }, uniquingKeysWith: { first, _ in first })
    }
    public func vector(_ text: RetrievalText) -> [Float]? { text.query ? queries[text.text] : documents[text.text] }
    public func require(_ texts: [RetrievalText]) throws {
        guard texts.allSatisfy({ vector($0) != nil }) else { throw Database.Failure(message: "Evidence has no indexed vector") }
    }
}
