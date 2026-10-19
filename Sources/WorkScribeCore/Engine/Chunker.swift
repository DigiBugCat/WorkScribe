import CryptoKit
import Foundation

public enum Chunker {
    public static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func chunks(_ passage: Passage) -> [Chunk] {
        let words = passage.text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty || passage.vector != nil else { return [] }
        var ranges: [Range<Int>] = []
        if words.count <= EngineConstants.chunkWords || passage.modality != .text { ranges = [0..<words.count] }
        else {
            var start = 0
            while start < words.count {
                let cap = min(start + EngineConstants.chunkWords, words.count)
                var end = cap
                if cap < words.count, let sentence = (start..<cap).last(where: { index in
                    words[index].trimmingCharacters(in: CharacterSet(charactersIn: "\"'’”)]")).last.map { ".!?".contains($0) } ?? false
                }) { end = sentence + 1 }
                ranges.append(start..<end); start = end
            }
            // The spec's short-tail join is the sole exception to the 60-word split point (maximum 74).
            if ranges.count > 1, let tail = ranges.last, tail.count < EngineConstants.chunkTailWords {
                ranges.removeLast(); let previous = ranges.removeLast(); ranges.append(previous.lowerBound..<tail.upperBound)
            }
        }
        return ranges.enumerated().map { piece, range in
            let text = words.count <= EngineConstants.chunkWords ? passage.text.trimmingCharacters(in: .whitespacesAndNewlines) : words[range].joined(separator: " ")
            var chunk = Chunk(kind: passage.kind, modality: passage.modality, start: passage.start, end: passage.end,
                              page: passage.page, track: passage.track, anchorSegment: passage.segmentIDs.first,
                              segmentIDs: passage.segmentIDs, speakers: passage.speaker.map { [$0] } ?? [],
                              speakerKeys: passage.speakerKey.map { [$0] } ?? [], text: text,
                              vector: ranges.count == 1 ? passage.vector : nil, thumbnail: passage.thumbnail, window: passage.window)
            chunk.source = passage.source; chunk.anchor = passage.anchor; chunk.context = passage.context
            chunk.id = String(hash([passage.source.key, passage.anchor, String(piece), text].joined(separator: "\u{0}")).prefix(32))
            if let start = passage.start, let end = passage.end, !words.isEmpty {
                chunk.start = start + (end - start) * Double(range.lowerBound) / Double(words.count)
                chunk.end = start + (end - start) * Double(range.upperBound) / Double(words.count)
            }
            return chunk
        }
    }
    public static func chunks(_ revision: SourceRevision) -> [Chunk] { revision.passages.flatMap(chunks) }
    /// Temporary planner projection; it has no splitting or grouping policy of its own.
    public static func transcript(_ meeting: Meeting) -> [TranscriptChunk] {
        chunks(MeetingSource.revision(meeting)).map {
            TranscriptChunk(id: $0.id, segmentID: $0.anchor, speaker: $0.speakers.first ?? "",
                            start: $0.start ?? 0, end: $0.end ?? 0, text: $0.text ?? "", segmentIDs: $0.segmentIDs)
        }
    }
}
