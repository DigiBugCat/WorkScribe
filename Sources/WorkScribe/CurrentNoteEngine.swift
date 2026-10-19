import Foundation
import WorkScribeCore

/// Stage 5 replaces the scheduling adapter; Line already owns every acceptance and revision guard.
enum CurrentNoteEngine {
    static let debounceSeconds = 0.0
    static let throttleSeconds = 0.0
    static func due(now: Double, lastRun: Double?, firstLine: Bool = false) -> Double {
        firstLine ? now : max(now + debounceSeconds, (lastRun ?? -Double.greatestFiniteMagnitude) + throttleSeconds)
    }
    static func revalidate(_ meeting: inout Meeting) -> Bool {
        let chunks = Dictionary(Chunker.transcript(meeting).map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
        var changed = false
        for i in (meeting.notes ?? []).indices {
            let refs = meeting.notes![i].line.evidence ?? []
            guard refs.contains(where: { chunks[$0] == nil }), meeting.notes![i].imageEvidence.isEmpty else { continue }
            let before = meeting.notes![i].line
            meeting.notes![i].line.retract(remaining: refs.compactMap { chunks[$0] }, jot: meeting.notes![i].text)
            changed = changed || before != meeting.notes![i].line
        }
        return changed
    }
    @discardableResult static func apply(_ draft: Enrichment, to meeting: inout Meeting, final: Bool, at: Date = Date()) -> Bool {
        guard !["purged", "purging"].contains(meeting.retention ?? "") else { return false }
        var stale = false
        for target in draft.plan.targets {
            guard let i = meeting.notes?.firstIndex(where: { $0.id == target.note.id }) else { continue }
            guard meeting.notes![i].queryRevision == target.note.queryRevision,
                  meeting.notes![i].line.revision == target.note.line.revision,
                  meeting.notes![i].text == target.note.text, meeting.notes![i].line.state != .yours else { stale = true; continue }
            guard let outcome = draft.outcomes[target.note.id], let basis = draft.bases[target.note.id] else { continue }
            var note = meeting.notes![i]
            note.line.apply(outcome, basis: basis, query: note.text, at: at)
            note.line.attemptedEvidence = Array(Set((note.line.attemptedEvidence ?? []) + draft.plan.evidence(for: target).map { $0.chunk.id })).sorted()
            note.line.seenThrough = max(note.line.seenThrough, target.note.line.seenThrough)
            var trace = note.trace ?? AITrace()
            trace.sources = draft.sceneSources[note.id]; trace.model = draft.model
            trace.location = draft.location; trace.durationMs = draft.durationMs
            trace.steps = [TraceStep("Matched transcript", detail: "\(target.refs.count) excerpts")]
            note.trace = trace
            if final { note.line.settle() }
            meeting.notes![i] = note
        }
        if final { for i in (meeting.notes ?? []).indices { meeting.notes![i].line.settle() } }
        return stale
    }
}
