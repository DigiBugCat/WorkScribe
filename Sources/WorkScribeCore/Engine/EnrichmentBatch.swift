import Foundation

public struct PromptEvidence: Equatable, Sendable {
    public var id: String
    public var chunk: TranscriptChunk
    public init(id: String, chunk: TranscriptChunk) { self.id = id; self.chunk = chunk }
}
public struct LineRequest: Equatable, Sendable {
    public var note: Note
    public var refs: [String]
    public var fresh: [String]
    public var previous: String?
    public var background: [BackgroundSnippet] = []
    public var backgroundOnly = false
    public var groups: [[String]] = []
    public init(note: Note, refs: [String], fresh: [String], previous: String?, background: [BackgroundSnippet] = [], backgroundOnly: Bool = false, groups: [[String]] = []) {
        self.note = note; self.refs = refs; self.fresh = fresh; self.previous = previous
        self.background = background; self.backgroundOnly = backgroundOnly; self.groups = groups
    }
}
/// Result of the relevance gate, independent of generation.
public struct Finding: Equatable, Sendable {
    public var rung: Rung?
    public var holding: Bool
    public var answerable: Bool
    public var candidates: Int
    public init(rung: Rung?, holding: Bool, answerable: Bool, candidates: Int) {
        self.rung = rung; self.holding = holding; self.answerable = answerable; self.candidates = candidates
    }
}
public struct EnrichmentBatch: Equatable, Sendable {
    public var findings: [String: Finding] = [:]
    public var targets: [LineRequest] = []
    public var excerpts: [PromptEvidence] = []
    public var chunkRefs: [String: [String]] = [:]
    public init() {}
    public var isEmpty: Bool { targets.isEmpty }
    public func evidence(for target: LineRequest) -> [PromptEvidence] {
        let refs = Set(target.refs)
        return excerpts.filter { refs.contains($0.id) }.sorted { $0.chunk.start == $1.chunk.start ? $0.id < $1.id : $0.chunk.start < $1.chunk.start }
    }
    public mutating func limitPromptTokens(_ maximum: Int, count: (LineRequest, [PromptEvidence]) -> Int) throws {
        for i in targets.indices {
            while count(targets[i], evidence(for: targets[i])) > maximum {
                if targets[i].groups.count == 1,
                   let id = targets[i].refs.last,
                   let e = excerpts.firstIndex(where: { $0.id == id }),
                   let boundary = excerpts[e].chunk.text.range(of: #"[.!?]\s+\S"#, options: [.regularExpression, .backwards]) {
                    let end = excerpts[e].chunk.text.index(after: boundary.lowerBound)
                    excerpts[e].chunk.text = String(excerpts[e].chunk.text[..<end])
                } else if let group = targets[i].groups.popLast() {
                    let remove = Set(group); targets[i].refs.removeAll { remove.contains($0) }
                    targets[i].fresh.removeAll { remove.contains($0) }
                } else if !targets[i].background.isEmpty { targets[i].background.removeLast() }
                else { throw BudgetFailure.promptTooLarge }
            }
            chunkRefs[targets[i].note.id] = evidence(for: targets[i]).map { $0.chunk.id }
        }
        let used = Set(targets.flatMap(\.refs)); excerpts.removeAll { !used.contains($0.id) }
    }
    public enum BudgetFailure: Error { case promptTooLarge }
}
