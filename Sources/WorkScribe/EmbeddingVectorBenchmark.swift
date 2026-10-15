import Foundation
import WorkScribeCore

/// Small public-text fixture: never reads meetings, notes, recordings or other user content.
enum EmbeddingVectorBenchmark {
    static func runIfAvailable() async throws -> [String: Any]? {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".runtime/models/embeddinggemma-2-coreml")
        guard let embedder = CoreMLEmbedder(directory: folder) ?? CoreMLEmbedder.bundled() else { return nil }
        let topics = [
            ("advertising budget", "We will cut marketing spend next quarter and review the paid advertising budget."),
            ("hiring a designer", "The product design candidate wants to work remotely before accepting our offer."),
            ("database outage", "Checkout was unavailable because the primary database ran out of disk space."),
            ("train tickets", "The team will travel by train and needs return tickets for Friday afternoon."),
            ("garden watering", "Water the vegetable garden early in the morning and check the irrigation timer."),
            ("audio recording", "The microphone track contains background noise; adjust the recording gain."),
            ("lease renewal", "The office lease expires in December; ask the landlord about renewal terms."),
            ("release testing", "Run the regression tests before shipping the next application release.")
        ]
        let documents = topics.flatMap { topic in (1...8).map { topic.1 + " This was discussed in planning session \($0)." } }
        let queries = topics.map(\.0) + topics.map { "What was decided about " + $0.0 + "?" }
        let vectors = try await embedder.texts(documents, role: .document(title: "Planning notes"))
        let stored = vectors.map { VectorMath.normalized($0.map { Float(Float16($0)) })! }
        let queryVectors = try await embedder.texts(queries, role: .query)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ws-real-vectors-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MappedVectorStore(url: root.appendingPathComponent("vectors"))
        try store.upsert(stored.enumerated().map { VectorRecord(id: Int64($0.offset), sourceID: Int64($0.offset / 8), kind: .document, vector: $0.element) })
        var compact: [Double] = [], reranked: [Double] = [], times: [Double] = []
        for q in queryVectors {
            let truth = Set(VectorMath.top(10, of: vectors, for: q).map { Int64($0.index) })
            let start = Date(), hits = try store.search(query: q, k: 200).matches
            times.append(Date().timeIntervalSince(start) * 1000)
            compact.append(Double(truth.intersection(hits.prefix(10).map(\.id)).count) / 10)
            let full = hits.sorted { VectorMath.dot(stored[Int($0.id)], q) > VectorMath.dot(stored[Int($1.id)], q) }
            reranked.append(Double(truth.intersection(full.prefix(10).map(\.id)).count) / 10)
        }
        await embedder.release()
        return ["model_id": embedder.modelID, "documents": documents.count, "queries": queries.count,
                "compact_recall_at_10": compact.reduce(0, +) / Double(compact.count),
                "reranked_recall_at_10": reranked.reduce(0, +) / Double(reranked.count),
                "mean_scan_ms": times.reduce(0, +) / Double(times.count),
                "scope": "64 public synthetic planning passages embedded by the installed real model; not a relevance benchmark"]
    }
}
