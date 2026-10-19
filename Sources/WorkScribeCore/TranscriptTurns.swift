import Foundation

/// A presentation/excerpt view over immutable recognition evidence. Never merges different
/// source/speaker identities, even when both have the same display name or are unidentified.
public struct TranscriptTurn {
    public var segments: [Segment]
    public var first: Segment { segments[0] }
    public var text: String { segments.map(\.text).joined(separator: " ") }
    public var end: Double { segments.map(\.end).max() ?? first.end }
}

public enum TranscriptTurns {
    public static func group(_ meeting: Meeting, maxWords: Int = 60, segments: [Segment]? = nil) -> [TranscriptTurn] {
        var result: [TranscriptTurn] = []
        for segment in segments ?? meeting.settledSegments {
            if let last = result.last,
               last.first.source == segment.source, last.first.speaker == segment.speaker,
               meeting.assignment(for: last.first) == meeting.assignment(for: segment),
               !segment.speaker.hasSuffix(":unknown"), !segment.speaker.hasSuffix("-0"),
               segment.start >= last.first.start, segment.start - last.end <= 1.5,
               segment.end - last.first.start <= 30,
               last.text.split(whereSeparator: \.isWhitespace).count < maxWords,
               !(last.text.last.map { ".?!".contains($0) } == true && last.text.split(whereSeparator: \.isWhitespace).count >= 12) {
                result[result.count - 1].segments.append(segment)
            } else { result.append(TranscriptTurn(segments: [segment])) }
        }
        return result
    }
}
