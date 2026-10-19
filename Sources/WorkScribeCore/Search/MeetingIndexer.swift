import Foundation

/// FNV-1a 64: stable across launches, unlike `Hasher`.
public struct StableHash {
    private var value: UInt64 = 0xcbf29ce484222325
    public init() {}
    public mutating func add(_ text: String) {
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 0x100000001b3 }
        value = (value ^ 0xff) &* 0x100000001b3   // separator, so ("ab","c") ≠ ("a","bc")
    }
    public var hex: String { String(format: "%016llx", value) }
}

public struct IndexReport: Sendable, Equatable {
    public var indexed = 0
    public var refreshed = 0
    public var unchanged = 0
    public var removed = 0
    public var skipped = 0
    public var failed = 0
    public init() {}
}

/// Keeps the index in step with the meeting library: new or changed meetings are re-chunked and embedded, renamed
/// speakers only update keyword text, deleted meetings leave the index. Without an embedder it indexes words only;
/// a later pass with one adds the vectors.
public struct MeetingIndexer: Sendable {
    public let index: SearchIndex
    public let embedder: (any Embedder)?
    /// Awaited before each embedding call: the app pauses indexing while recording.
    public let gate: @Sendable () async -> Void

    public init(index: SearchIndex, embedder: (any Embedder)?, gate: @escaping @Sendable () async -> Void = {}) {
        self.index = index; self.embedder = embedder; self.gate = gate
    }

    /// Meetings that are still being recorded wait until they are finalized.
    public static func isIndexable(_ meeting: Meeting) -> Bool {
        meeting.retention != "purged" && meeting.retention != "purging" && meeting.status != "recording" && meeting.status != "finalizing"
            && (!meeting.segments.isEmpty || (meeting.screen?.momentCount ?? 0) > 0)
    }

    public func sync(store: MeetingStore) async throws -> IndexReport {
        if let embedder { try index.adopt(modelID: embedder.modelID) }
        var report = IndexReport()
        let meetings = store.list()
        let live = Set(meetings.map(\.id))
        for source in try index.sources(kind: .meeting) where !live.contains(source.ref) {
            try index.remove(ref: source.ref); report.removed += 1
        }
        for meeting in meetings {
            try Task.checkCancellation()
            guard Self.isIndexable(meeting) else { report.skipped += 1; continue }
            do {
                // A deleted screen recording leaves no moments file, so its chunks drop out here.
                let screen = meeting.screen == nil ? [] : store.loadScreenMoments(meeting.id)
                switch try await index(meeting, screen: screen, folder: try? store.directory(meeting.id)) {
                case .indexed: report.indexed += 1
                case .refreshed: report.refreshed += 1
                case .unchanged: report.unchanged += 1
                }
                if let latest = try? store.load(meeting.id), latest.retention == "purged" || latest.retention == "purging" { try index.purge(refs: [meeting.id]) }
            } catch is CancellationError { throw CancellationError() }
            catch { report.failed += 1 }
        }
        return report
    }

    public enum Outcome: Sendable { case indexed, refreshed, unchanged }

    @discardableResult
    public func index(_ meeting: Meeting, screen: [ScreenMoment] = [], folder: URL? = nil) async throws -> Outcome {
        if let embedder { try index.adopt(modelID: embedder.modelID) }
        let fingerprint = MeetingSource.fingerprint(meeting, screen: screen)
        // Without an available model, reuse only the index's current space (or establish the first one).
        // An older meeting must not evict the rest of the library's vectors during keyword-only indexing.
        let space = embedder?.modelID ?? index.vectorModel ?? screen.last(where: { $0.embedding != nil })?.embeddingModelID
        let compatible = screen.map { scene -> ScreenMoment in
            var scene = scene
            if scene.embeddingModelID != space || scene.embeddingModelID == nil { scene.embedding = nil }
            return scene
        }
        if index.vectorModel == nil, let space { try index.adopt(modelID: space) }
        let hasScenes = compatible.contains { $0.embedding != nil }
        let existing = try index.source(ref: meeting.id)
        if let existing, existing.fingerprint == fingerprint,
           embedder != nil ? existing.modelID == embedder?.modelID : (!hasScenes || existing.modelID == space) {
            guard existing.voiceRevision != meeting.voiceRevision else { return .unchanged }
            let names = Self.names(meeting)
            try index.updateSpeakers(ref: meeting.id, voiceRevision: meeting.voiceRevision, title: meeting.title) { names[$0] ?? $0 }
            return .refreshed
        }
        var revision = MeetingSource.revision(meeting)
        revision.fingerprint = fingerprint
        revision.passages += ScreenSource.passages(compatible, meeting: meeting, folder: folder)
        _ = try index.apply(revision)
        if let embedder { try await index.embedMissing(revision.source, using: embedder, gate: gate) }
        return .indexed
    }

    /// Current display name per raw speaker key. A per-line override (`segmentAssignments`) is resolved through the
    /// chunk's stored names at the next re-chunk; speaker-level names apply at once.
    static func names(_ meeting: Meeting) -> [String: String] {
        var out: [String: String] = [:]
        for segment in meeting.segments where out[segment.speaker] == nil {
            out[segment.speaker] = meeting.speakerAssignments?[segment.speaker].flatMap { $0.name.isEmpty ? nil : $0.name }
                ?? Meeting.originalSpeakerName(segment.speaker)
        }
        return out
    }
}
