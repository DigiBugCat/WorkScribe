import Foundation

/// A read-only view for optional meeting summaries after the line queue settles.
public enum UncoveredDiscussion {
    public static func excerpts(_ meeting: Meeting) -> [PromptEvidence] {
        let used = Set((meeting.notes ?? []).flatMap { $0.line.evidence ?? [] })
        return Chunker.transcript(meeting).filter { !used.contains($0.id) && $0.words >= 8 }
            .enumerated().map { PromptEvidence(id: "U\($0.offset + 1)", chunk: $0.element) }
    }
}
