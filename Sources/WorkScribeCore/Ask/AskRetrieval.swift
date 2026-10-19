import Foundation

/// Combining what retrieval found, and finding moments in a meeting that isn't indexed yet (the live one).
public enum AskRetrieval {
    /// Moments from the conversation's own sources (attachments, the live or scoped meeting) come first, up to
    /// `priorityShare`; the rest of the budget goes to everything else. Duplicates (same chunk, or the same place in
    /// the same source) are dropped, keeping the first.
    public static func merge(priority: [AskMoment], general: [AskMoment], limit: Int, priorityShare: Int) -> [AskMoment] {
        var out: [AskMoment] = []
        var seen = Set<String>()
        func add(_ moment: AskMoment) -> Bool {
            guard out.count < limit else { return false }
            let place = "\(moment.ref)|\(moment.page ?? -1)|\(moment.start.map { Int($0) } ?? -1)"
            guard seen.insert(moment.id).inserted, seen.insert(place).inserted else { return false }
            out.append(moment); return true
        }
        var taken = 0
        for moment in priority where taken < priorityShare { if add(moment) { taken += 1 } }
        for moment in general { _ = add(moment) }
        // Room left (few general hits): the rest of the priority moments.
        for moment in priority.dropFirst(taken) { _ = add(moment) }
        return out
    }

    /// Keyword moments from a meeting's transcript, for the meeting being recorded (indexing waits until it's saved).
    /// When nothing matches ("what did she just say?") the latest stretch of the conversation is returned instead.
    public static func liveMoments(question: String, meeting: Meeting, limit: Int = 4,
                                   matcher: any NoteMatcher = LexicalMatcher()) -> [AskMoment] {
        let chunks = Chunker.transcript(meeting)
        guard !chunks.isEmpty else { return [] }
        let scores = (try? matcher.similarities(notes: [question], chunks: chunks.map(\.text)).first) ?? []
        var ranked = chunks.indices.filter { $0 < scores.count && scores[$0] > 0.05 }
            .sorted { scores[$0] > scores[$1] || (scores[$0] == scores[$1] && $0 > $1) }
        if ranked.isEmpty { ranked = Array(chunks.indices.suffix(limit).reversed()) }
        return ranked.prefix(limit).map { index in
            let chunk = chunks[index]
            return AskMoment(id: "live:\(chunk.id)", sourceKind: SourceKind.meeting.rawValue,
                             ref: meeting.id, title: meeting.title, kind: ChunkKind.meetingSegment.rawValue,
                             start: chunk.start, end: chunk.end, anchorSegment: chunk.segmentID,
                             speakers: [chunk.speaker], text: chunk.text,
                             snippet: SearchText.excerpt(chunk.text), attached: true)
        }
    }
}
