import Foundation

/// Groups a meeting's transcript segments into spans of about 20–40 s for embedding. Text search over our own
/// transcript beat raw-audio windows on DigUp's comparison (exact segment 6 of 6 vs within 30 s), so meetings are
/// indexed as text. Speaker names stay out of the embedded text: renaming a voice must not force a re-embed.
public enum MeetingChunker {
    public static let minimumSeconds = 20.0
    public static let maximumSeconds = 40.0
    public static let maximumCharacters = 1_200

    public static func chunks(_ meeting: Meeting) -> [Chunk] {
        var chunks: [Chunk] = []
        var group: [Segment] = []
        func flush() {
            guard let first = group.first, let last = group.last else { return }
            let text = group.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
            defer { group = [] }
            guard !text.isEmpty else { return }
            var seen = Set<String>(), seenKeys = Set<String>()
            let tracks = Set(group.map(\.source))
            chunks.append(Chunk(kind: .meetingSegment, modality: .text, start: first.start, end: group.map(\.end).max() ?? last.end,
                                track: tracks.count == 1 ? tracks.first : nil, anchorSegment: first.id,
                                segmentIDs: group.map(\.id),
                                speakers: group.map { meeting.speakerName(for: $0) }.filter { seen.insert($0).inserted },
                                speakerKeys: group.map(\.speaker).filter { seenKeys.insert($0).inserted }, text: text))
        }
        for segment in pieces(meeting.orderedSegments) {
            if let first = group.first {
                let span = segment.end - first.start
                let characters = group.reduce(0) { $0 + $1.text.count } + segment.text.count
                let current = (group.last?.end ?? first.start) - first.start
                if (span > maximumSeconds && current >= minimumSeconds) || characters > maximumCharacters || span > maximumSeconds * 1.5 {
                    flush()
                }
            }
            group.append(segment)
        }
        flush()
        // A short tail joins the chunk before it when the two still fit.
        if chunks.count >= 2, let tail = chunks.last, let before = chunks.dropLast().last,
           (tail.end ?? 0) - (tail.start ?? 0) < minimumSeconds / 2,
           (tail.end ?? 0) - (before.start ?? 0) <= maximumSeconds * 1.25,
           (before.text?.count ?? 0) + (tail.text?.count ?? 0) <= maximumCharacters {
            var merged = before
            merged.end = tail.end
            merged.text = [before.text, tail.text].compactMap { $0 }.joined(separator: " ")
            merged.segmentIDs += tail.segmentIDs
            merged.speakers += tail.speakers.filter { !before.speakers.contains($0) }
            merged.speakerKeys += tail.speakerKeys.filter { !before.speakerKeys.contains($0) }
            if merged.track != tail.track { merged.track = nil }
            chunks.removeLast(2)
            chunks.append(merged)
        }
        return chunks
    }

    /// Segments longer than the maximum (one person talking for minutes) are split by words, with times interpolated.
    /// Pieces keep their segment's ID so a link still lands on the right row.
    static func pieces(_ segments: [Segment]) -> [Segment] {
        segments.flatMap { segment -> [Segment] in
            let duration = segment.end - segment.start
            let words = segment.text.split(whereSeparator: \.isWhitespace)
            guard duration > maximumSeconds || segment.text.count > maximumCharacters, words.count > 1 else { return [segment] }
            let parts = max(Int((duration / (maximumSeconds * 0.75)).rounded(.up)),
                            Int((Double(segment.text.count) / Double(maximumCharacters) * 1.25).rounded(.up)), 2)
            let size = Int((Double(words.count) / Double(parts)).rounded(.up))
            return stride(from: 0, to: words.count, by: size).map { start in
                var piece = segment
                let end = min(start + size, words.count)
                piece.text = words[start..<end].joined(separator: " ")
                piece.start = segment.start + duration * Double(start) / Double(words.count)
                piece.end = segment.start + duration * Double(end) / Double(words.count)
                return piece
            }
        }
    }

    /// Changes whenever the embedded content changes: the title and every segment's text and times. Speaker names
    /// are tracked separately (`Meeting.voiceRevision`).
    public static func fingerprint(_ meeting: Meeting, screen: [ScreenMoment] = []) -> String {
        var hasher = StableHash()
        hasher.add(meeting.title)
        for segment in meeting.orderedSegments {
            hasher.add(segment.id); hasher.add(segment.text)
            hasher.add(String(format: "%.2f-%.2f", segment.start, segment.end))
        }
        // Screen moments only change the fingerprint when there are some: audio-only meetings keep theirs.
        guard !screen.isEmpty else { return "m1:\(meeting.segments.count):\(hasher.hex)" }
        ScreenChunker.add(screen, to: &hasher)
        return "m1:\(meeting.segments.count)+s\(screen.count):\(hasher.hex)"
    }
}

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
        let fingerprint = MeetingChunker.fingerprint(meeting, screen: screen)
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
        var chunks = MeetingChunker.chunks(meeting) + ScreenChunker.chunks(compatible, meeting: meeting, folder: folder)
        var modelID: String? = hasScenes ? space : nil
        if let embedder {
            let embeddable = chunks.indices.filter { chunks[$0].vector == nil && (chunks[$0].text.map(SearchText.hasWords) ?? false) }
            for batch in stride(from: 0, to: embeddable.count, by: 32) {
                await gate()
                try Task.checkCancellation()
                let rows = Array(embeddable[batch..<min(batch + 32, embeddable.count)])
                let vectors = try await embedder.texts(rows.map { chunks[$0].text ?? "" }, role: .document(title: meeting.title))
                for (row, vector) in zip(rows, vectors) { chunks[row].vector = VectorMath.normalized(vector) }
            }
            modelID = embedder.modelID
        }
        try index.replace(kind: .meeting, ref: meeting.id, title: meeting.title, startedAt: meeting.startedAt,
                          fingerprint: fingerprint, modelID: modelID, voiceRevision: meeting.voiceRevision, chunks: chunks)
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
