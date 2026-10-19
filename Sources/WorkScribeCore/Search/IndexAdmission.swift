import Foundation

/// One embedding call at a time. A call already on the accelerator is not preemptible;
/// admission between calls prefers live chunks, then interactive queries, then backlog.
public actor IndexAdmission {
    public enum Priority: Int, Sendable { case live, query, backlog }
    private struct Waiting {
        var id: UUID
        var priority: Priority
        var continuation: CheckedContinuation<Void, Error>
    }
    private var waiting: [Waiting] = []
    private var occupied = false
    private var pressure: RecordingPressure = .normal
    public init() {}
    public func setPressure(_ value: RecordingPressure) { pressure = value; drain() }
    public func acquire(_ priority: Priority) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waiting.append(Waiting(id: id, priority: priority, continuation: continuation))
                drain()
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let i = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: i).continuation.resume(throwing: CancellationError())
    }
    private func drain() {
        guard !occupied, pressure < .aiPaused,
              let priority = waiting.map(\.priority.rawValue).min(),
              let i = waiting.firstIndex(where: { $0.priority.rawValue == priority }) else { return }
        occupied = true
        waiting.remove(at: i).continuation.resume()
    }
    public func release() { occupied = false; drain() }
}

/// Backlog batches are deliberately two chunks, independent of the caller's batch size.
/// The same admission object is shared by the indexer and the note/Ask query embedder.
public struct AdmittedEmbedder: Embedder {
    public let base: any Embedder
    public let admission: IndexAdmission
    public let priority: IndexAdmission.Priority
    public init(_ base: any Embedder, admission: IndexAdmission, priority: IndexAdmission.Priority) {
        self.base = base; self.admission = admission; self.priority = priority
    }
    public var modelID: String { base.modelID }
    public var dimension: Int { base.dimension }
    public var supportsAudio: Bool { base.supportsAudio }
    public var supportsImages: Bool { base.supportsImages }
    private func run<T>(_ body: () async throws -> T) async throws -> T {
        try await admission.acquire(priority)
        let start = Date()
        do {
            try Task.checkCancellation()
            let result = try await body()
            await admission.release()
            log(start)
            return result
        } catch { await admission.release(); throw error }
    }
    private func log(_ start: Date) {
        guard ProcessInfo.processInfo.environment["WORKSCRIBE_INDEX_METRICS"] == "1" else { return }
        let row: [String: Any] = ["event": "index_embedding", "priority": priority.rawValue,
            "time": Date().timeIntervalSince1970, "duration_ms": Date().timeIntervalSince(start) * 1000]
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
            FileHandle.standardError.write(data + Data([10]))
        }
    }
    public func text(_ value: String, role: TextRole) async throws -> [Float] {
        try await run { try await base.text(value, role: role) }
    }
    public func texts(_ values: [String], role: TextRole) async throws -> [[Float]] {
        var result: [[Float]] = []
        for offset in stride(from: 0, to: values.count, by: 2) {
            let batch = Array(values[offset..<min(offset + 2, values.count)])
            result += try await run { try await base.texts(batch, role: role) }
            await Task.yield()
        }
        return result
    }
    public func audio(_ pcm16k: [Float]) async throws -> [Float] { try await run { try await base.audio(pcm16k) } }
    public func image(_ url: URL) async throws -> [Float] { try await run { try await base.image(url) } }
}
