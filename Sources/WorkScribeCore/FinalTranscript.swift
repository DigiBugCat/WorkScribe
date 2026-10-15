import Foundation

/// Quality-pass words carry the batch decoder's spelling and punctuation. Timings stay
/// on the meeting clock; identity and speakers come from the live diarization timeline.
public struct TranscriptWord: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}

public enum FinalTranscript {
    /// Partition by time, not text equality: batch recognition is allowed to correct every word.
    /// Reuse each live segment's ID at most once, and preserve its manually assigned speaker.
    public static func aligned(_ words: [TranscriptWord], source: String, originals: [Segment],
                               unknownSpeaker: String) -> [Segment] {
        let originals = originals.filter { $0.source == source }.sorted { $0.start < $1.start }
        var result: [Segment] = [], used = Set<String>(), previousAnchor: String?
        for word in words.sorted(by: { $0.start < $1.start }) where !word.text.isEmpty {
            let middle = (word.start + word.end) / 2
            let nearest = originals.min { a, b in
                distance(middle, a) < distance(middle, b)
            }
            // An ASR omission in a long silence must not borrow a remote speaker label.
            let anchor = nearest.flatMap { distance(middle, $0) <= 2 ? $0 : nil }
            let speaker = anchor?.speaker ?? unknownSpeaker
            if let last = result.last, last.speaker == speaker,
               word.start - last.end < 1.5, word.end - last.start < 30,
               anchor?.id == previousAnchor,
               last.text.split(whereSeparator: \.isWhitespace).count < 60 {
                result[result.count - 1].text += " " + word.text
                result[result.count - 1].end = max(last.end, word.end)
            } else {
                var segment = Segment(source: source, speaker: speaker, start: word.start, end: max(word.start, word.end), text: word.text)
                if let anchor, used.insert(anchor.id).inserted { segment.id = anchor.id }
                result.append(segment)
            }
            previousAnchor = anchor?.id
        }
        return result
    }
    private static func distance(_ time: Double, _ segment: Segment) -> Double {
        max(segment.start - time, time - segment.end, 0)
    }
}
