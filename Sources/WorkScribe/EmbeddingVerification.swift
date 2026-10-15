import Foundation
import WorkScribeCore

/// `WorkScribe --verify-embedding [model folder]`: loads EmbeddingGemma 2, embeds a few queries and passages, and
/// prints cosine similarities and timings as JSON. Text runs on .cpuAndNeuralEngine, audio on .cpuAndGPU.
enum EmbeddingVerification {
    static func run() async throws {
        let arguments = CommandLine.arguments
        let folder = arguments.firstIndex(of: "--verify-embedding").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        guard let embedder = folder.flatMap({ CoreMLEmbedder(directory: URL(fileURLWithPath: $0)) }) ?? CoreMLEmbedder.bundled() else {
            throw EmbedderError.unavailable("no EmbeddingGemma 2 model; run scripts/prepare-embedding-model.py")
        }
        let queries = ["cutting the advertising budget", "hiring a product designer", "database outage postmortem",
                       "who is sending the spreadsheet"]
        let documents = ["We should cut the ad spend by a third next quarter, marketing is over budget.",
                         "The candidate for the design role wants to work remotely; we'd like to make an offer.",
                         "Checkout was down for forty minutes last night because the primary database ran out of disk.",
                         "Priya will send the revenue spreadsheet to everyone after the call."]
        func time<T>(_ body: () async throws -> T) async rethrows -> (T, Double) {
            let start = Date(); let value = try await body(); return (value, Date().timeIntervalSince(start))
        }
        let (_, firstCall) = try await time { try await embedder.text("warm up", role: .query) }
        let load = await embedder.lastLoadSeconds ?? 0
        let (queryVectors, querySeconds) = try await time { try await embedder.texts(queries, role: .query) }
        let (documentVectors, documentSeconds) = try await time { try await embedder.texts(documents, role: .document(title: nil)) }
        var single: [Double] = []
        for query in queries { single.append(try await time { try await embedder.text(query, role: .query) }.1) }
        let matrix = queryVectors.map { q in documentVectors.map { Double(VectorMath.dot(q, $0) * 1000).rounded() / 1000 } }
        let correct = matrix.enumerated().filter { row, values in values.firstIndex(of: values.max()!) == row }.count
        var result: [String: Any] = [
            "model_id": embedder.modelID, "dimension": embedder.dimension, "text_compute_units": "cpuAndNeuralEngine",
            "load_seconds": load, "first_call_seconds_including_load": firstCall,
            "batch_4_queries_seconds": querySeconds, "batch_4_documents_seconds": documentSeconds,
            "single_query_seconds": single, "cosine_query_by_document": matrix, "top1_correct": "\(correct)/\(queries.count)",
            "queries": queries, "documents": documents, "audio_supported": embedder.supportsAudio,
        ]
        if embedder.supportsAudio {
            let tone = (0..<Embedders.audioWindowSamples).map { Float(sin(Double($0) * 0.05) * 0.1) }
            let (vector, seconds) = try await time { try await embedder.audio(tone) }
            result["audio_compute_units"] = "cpuAndGPU"
            result["audio_window_seconds_including_load"] = seconds
            result["audio_dimension"] = vector.count
        }
        result["index_round_trip"] = try await indexRoundTrip(embedder, documents: documents, queries: queries)
        await embedder.release()
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    /// The same passages as a throwaway meeting (25 s each), indexed and searched through `SearchIndex`.
    static func indexRoundTrip(_ embedder: CoreMLEmbedder, documents: [String], queries: [String]) async throws -> [[String: Any]] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workscribe-embed-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root.appendingPathComponent("Meetings"))
        var meeting = Meeting(title: "Verification")
        meeting.status = "complete"
        meeting.segments = documents.enumerated().map { index, text in
            Segment(source: "system", speaker: "system:speaker-\(index + 1)", start: Double(index) * 25, end: Double(index) * 25 + 24, text: text)
        }
        try store.save(meeting)
        let index = try SearchIndex(url: root.appendingPathComponent("index.sqlite"))
        let started = Date()
        _ = try await MeetingIndexer(index: index, embedder: embedder).sync(store: store)
        let indexSeconds = Date().timeIntervalSince(started)
        var out: [[String: Any]] = []
        for query in queries {
            let vector = try await embedder.text(query, role: .query)
            let hits = try index.search(SearchRequest(query, perSource: nil), queryVector: vector, queryModelID: embedder.modelID).hits
            out.append(["query": query, "top_start_seconds": hits.first?.start as Any? ?? NSNull(),
                        "top_match": hits.first?.match.rawValue as Any? ?? NSNull(), "hits": hits.count,
                        "top_link": hits.first?.link.url.absoluteString as Any? ?? NSNull(), "index_seconds": indexSeconds])
        }
        return out
    }
}
