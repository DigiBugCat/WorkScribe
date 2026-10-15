import Accelerate
import Darwin
import Foundation

/// Reproducible, bounded-memory benchmark. Synthetic data is deliberately clustered, with correlated
/// leading dimensions and independent residual noise. It is not an EmbeddingGemma retrieval evaluation.
public enum VectorBenchmark {
    public static func run(count: Int, repeats: Int = 30) throws -> [String: Any] {
        guard count > 0, count <= 2_000_000 else { throw EmbedderError.badVector("benchmark N must be 1...2000000") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ws-vector-bench-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MappedVectorStore(url: root.appendingPathComponent("vectors"))
        let fullURL = root.appendingPathComponent("full.f32")
        _ = FileManager.default.createFile(atPath: fullURL.path, contents: nil)
        let full = try FileHandle(forWritingTo: fullURL)
        let started = Date()
        let generator = ClusteredVectors()
        for base in stride(from: 0, to: count, by: 2048) {
            var records: [VectorRecord] = [], bytes = Data(capacity: 2048 * 768 * 4)
            for id in base..<min(count, base + 2048) {
                let vector = generator.vector(id)
                records.append(VectorRecord(id: Int64(id + 1), sourceID: Int64(id / 100), kind: .document, vector: vector))
                vector.withUnsafeBytes { bytes.append(contentsOf: $0) }
            }
            try store.upsert(records)
            try full.write(contentsOf: bytes)
        }
        try full.synchronize(); try full.close(); try store.persist(checkpoint: Int64(count))
        let build = Date().timeIntervalSince(started)
        let firstScanStart = Date()
        _ = try store.search(query: generator.vector(count), k: 200)
        let firstScanMS = Date().timeIntervalSince(firstScanStart) * 1000
        let storeRSS = residentBytes()
        let exactData = try Data(contentsOf: fullURL, options: [.alwaysMapped])
        var latencies: [Double] = [], endToEnd: [Double] = [], vdsp: [Double] = [], recalls: [Double] = []
        var candidateRecalls: [Double] = []
        var exactTimes: [Double] = []
        for i in 0..<repeats {
            let query = generator.vector(count + i * 7919)
            let begin = Date()
            let candidates = try store.search(query: query, k: 200)
            latencies.append(Date().timeIntervalSince(begin) * 1000)
            let reranked: [VectorMatch] = exactData.withUnsafeBytes { bytes in
                candidates.matches.map { hit in
                    let p = bytes.baseAddress!.advanced(by: Int(hit.id - 1) * 768 * 4).assumingMemoryBound(to: Float.self)
                    let stored = VectorMath.normalized((0..<768).map { Float(Float16(p[$0])) })!
                    return VectorMatch(id: hit.id, score: VectorMath.dot(stored, query))
                }.sorted { $0.score > $1.score }
            }
            endToEnd.append(Date().timeIntervalSince(begin) * 1000)
            // Ten independent exact 768-d truth scans, including the same full-vector normalization.
            if i < 10 {
                let exactStart = Date()
                var heap = VectorHeap(capacity: 10)
                exactData.withUnsafeBytes { bytes in
                    let p = bytes.baseAddress!.assumingMemoryBound(to: Float.self)
                    for row in 0..<count {
                        var score: Float = 0
                        vDSP_dotpr(p.advanced(by: row * 768), 1, query, 1, &score, 768)
                        heap.add(VectorMatch(id: Int64(row + 1), score: score))
                    }
                }
                exactTimes.append(Date().timeIntervalSince(exactStart) * 1000)
                let truth = Set(heap.sorted.map(\.id))
                recalls.append(Double(truth.intersection(reranked.prefix(10).map(\.id)).count) / Double(min(10, count)))
                candidateRecalls.append(Double(truth.intersection(candidates.matches.map(\.id)).count) / Double(min(10, count)))
            }
        }
        store.kernel = .vdsp
        for i in 0..<repeats {
            let query = generator.vector(count + i * 7919), start = Date()
            _ = try store.search(query: query, k: 200)
            vdsp.append(Date().timeIntervalSince(start) * 1000)
        }
        let stats = try store.stats
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        func percentile(_ a: [Double], _ p: Double) -> Double { a.sorted()[min(a.count - 1, Int(ceil(Double(a.count) * p)) - 1)] }
        return ["count": count, "build_seconds": build, "mapped_bytes": stats.mappedBytes,
                "store_resident_bytes": storeRSS, "peak_process_rss_bytes": usage.ru_maxrss, "workers": store.workers,
                "queries": repeats, "truth_queries": recalls.count, "first_scan_ms": firstScanMS, "simd_p50_ms": percentile(latencies, 0.5),
                "simd_p95_ms": percentile(latencies, 0.95), "vdsp_p50_ms": percentile(vdsp, 0.5),
                "vdsp_p95_ms": percentile(vdsp, 0.95), "rerank_p50_ms": percentile(endToEnd, 0.5),
                "rerank_p95_ms": percentile(endToEnd, 0.95), "exact768_p50_ms": percentile(exactTimes, 0.5),
                "recall_at_10": recalls.reduce(0, +) / Double(recalls.count),
                "candidate_recall_at_200": candidateRecalls.reduce(0, +) / Double(candidateRecalls.count)]
    }
    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.resident_size : 0
    }

}

private struct ClusteredVectors {
    let centers: [[Float]]
    let details: [[Float]]
    init() {
        func random(_ seed: Int) -> [Float] {
            var rng = VectorRandom(state: UInt64(seed + 1))
            return (0..<768).map { _ in rng.next() }
        }
        centers = (0..<128).map { VectorMath.normalized(random($0 + 8000))! }
        details = (0..<2048).map { VectorMath.normalized(random($0 + 9000))! }
    }
    func vector(_ id: Int) -> [Float] {
        var rng = VectorRandom(state: UInt64(id + 19001))
        let center = centers[id % centers.count], detail = details[(id / centers.count) % details.count]
        return VectorMath.normalized((0..<768).map { d in
            center[d] + detail[d] * 0.4 + rng.next() * 0.005
        })!
    }
}
private struct VectorRandom {
    var state: UInt64
    mutating func next() -> Float {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Float(state & 0xffffff) / Float(0x800000) - 1
    }
}
