import Foundation

/// Speakers playing a call into the room make the microphone hear the other side a second time.
/// Acoustic echo cancellation removes most of it at capture; this is the safety net for whatever
/// gets through (no voice processing, a loud room, a second device): a microphone segment that
/// overlaps system audio in time and says largely the same words is that system speech, misheard.
///
/// Pure and deterministic. The user talking over the call keeps their own words, because those
/// words are not in the system transcript at that moment.
public enum EchoFilter {
    public struct Policy: Sendable {
        /// The two clocks start a few hundred milliseconds apart and recognition timing jitters.
        public var slack = 1.5
        /// Fraction of the microphone segment's words that must be heard on the system channel.
        public var minMatch = 0.5
        /// A fragment this short with no lexical match is echo only when it sits between echoes,
        /// inside system speech ("One more thing" heard as "I killed in").
        public var fragmentWords = 3
        /// A longer segment between echoes needs some lexical support ("I'll tell how this are
        /// known" for "I'll tell Halverson"): this fraction of its words heard on the system side.
        public var contextMatch = 0.25
        /// Echo that survived cancellation is garbled ("Friday on John says online that you end up a
        /// year" for "on Friday their contract says offline capture by the end of the year"): a
        /// segment lying mostly inside system speech with this many of its content words heard there
        /// and this fraction overall is echo too. Someone talking over the call shares few content words.
        public var garbledMatch = 0.35
        public var garbledContentWords = 4
        public var garbledInside = 0.7
        /// Neighbouring echoes must be this close for the fragment rule.
        public var neighbourGap = 2.0
        public init() {}
    }

    public struct Match: Equatable, Sendable {
        public var echoID: String
        public var systemID: String
        /// Matched fraction of the echo's words; 0 for fragments kept by context.
        public var score: Double
    }

    /// Microphone segments that duplicate system speech, each with the system segment it repeats.
    public static func matches(_ segments: [Segment], policy: Policy = Policy()) -> [Match] {
        let system = segments.filter { $0.source == "system" }.sorted { $0.start < $1.start }
        let microphone = segments.filter { $0.source == "microphone" }.sorted { $0.start < $1.start }
        guard !system.isEmpty, !microphone.isEmpty else { return [] }
        let heard = system.flatMap(timedWords).sorted { $0.start < $1.start }
        var result: [String: Match] = [:], partial: [String: Double] = [:]
        for segment in microphone {
            let words = keys(segment.text)
            guard !words.isEmpty else { continue }
            let low = segment.start - policy.slack, high = segment.end + policy.slack
            let nearby = heard.filter { $0.end >= low && $0.start <= high }
            guard !nearby.isEmpty else { continue }
            var owners: [String: Int] = [:], matched = 0, content = 0
            for word in words {
                if let hit = nearby.first(where: { similar(word, $0.key) }) {
                    matched += 1; owners[hit.segmentID, default: 0] += 1
                    if word.count >= 3, !LexicalMatcher.stopwords.contains(word) { content += 1 }
                }
            }
            let score = Double(matched) / Double(words.count)
            partial[segment.id] = score
            let duration = max(0.01, segment.end - segment.start)
            let inside = system.reduce(0.0) { $0 + max(0, min(segment.end, $1.end + policy.slack) - max(segment.start, $1.start - policy.slack)) } / duration
            let garbled = score >= policy.garbledMatch && content >= policy.garbledContentWords && inside >= policy.garbledInside
            guard score >= policy.minMatch || garbled, let owner = owners.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }) else { continue }
            result[segment.id] = Match(echoID: segment.id, systemID: owner.key, score: score)
        }
        // Fragments inside system speech, between two echoes, are echo the recognizer could not
        // spell. A lone "yeah" over the call has no echo on either side and stays.
        for (index, segment) in microphone.enumerated() where result[segment.id] == nil {
            guard keys(segment.text).count <= policy.fragmentWords || (partial[segment.id] ?? 0) >= policy.contextMatch,
                  let inside = system.first(where: { $0.start - policy.slack <= segment.start && segment.end <= $0.end + policy.slack }),
                  index > 0, index + 1 < microphone.count else { continue }
            let before = microphone[index - 1], after = microphone[index + 1]
            guard result[before.id] != nil, result[after.id] != nil,
                  segment.start - before.end <= policy.neighbourGap, after.start - segment.end <= policy.neighbourGap else { continue }
            result[segment.id] = Match(echoID: segment.id, systemID: inside.id, score: 0)
        }
        return microphone.compactMap { result[$0.id] }
    }

    /// Lowercased letters and digits per word: "Marcus," and "marcus" are the same word.
    public static func keys(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: \.isWhitespace)
            .map { String($0.filter { $0.isLetter || $0.isNumber }) }.filter { !$0.isEmpty }
    }

    /// Tolerant of recognition errors: "merch"/"merge", "counts"/"accounts", "ride"/"right".
    public static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let shorter = min(a.count, b.count), longer = max(a.count, b.count)
        if shorter >= 3 && (a.hasPrefix(b) || b.hasPrefix(a)) { return true }
        if shorter >= 4 && (a.hasSuffix(b) || b.hasSuffix(a)) { return true }
        guard shorter >= 4, longer - shorter <= 2 else { return false }
        return distance(a, b) <= (shorter >= 5 ? 2 : 1)
    }

    struct HeardWord { var key: String; var start: Double; var end: Double; var segmentID: String }

    /// Segments carry no per-word times; spread the words across the segment by length.
    static func timedWords(_ segment: Segment) -> [HeardWord] {
        let words = keys(segment.text)
        guard !words.isEmpty else { return [] }
        let total = Double(words.reduce(0) { $0 + $1.count + 1 })
        let duration = max(0, segment.end - segment.start)
        var cursor = 0.0
        return words.map { word in
            let start = segment.start + duration * cursor / total
            cursor += Double(word.count + 1)
            return HeardWord(key: word, start: start, end: segment.start + duration * cursor / total, segmentID: segment.id)
        }
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}

extension Meeting {
    /// Moves microphone echoes of system speech out of the transcript. They are kept in
    /// `echoSegments` for audit, and evidence that cited one now resolves to the system segment.
    /// Returns how many segments moved. Idempotent.
    @discardableResult
    public mutating func removeEchoes(policy: EchoFilter.Policy = EchoFilter.Policy()) -> Int {
        let found = EchoFilter.matches(segments, policy: policy)
        guard !found.isEmpty else { return 0 }
        let ids = Set(found.map(\.echoID))
        let moved = segments.filter { ids.contains($0.id) }
        segments.removeAll { ids.contains($0.id) }
        echoSegments = (echoSegments ?? []) + moved
        var aliases = transcriptAliases ?? [:]
        for match in found where aliases[match.echoID] == nil { aliases[match.echoID] = match.systemID }
        transcriptAliases = aliases
        return moved.count
    }

    /// The transcript that may be quoted as evidence right now. While the system channel is still
    /// recognizing an utterance, a microphone segment from that stretch may yet turn out to be its
    /// echo; it waits until the system side completes. After recording, this is every segment.
    public var settledSegments: [Segment] {
        let ordered = orderedSegments
        guard status == "recording", let pending = partials["system"], !pending.isEmpty else { return ordered }
        let systemEnd = ordered.last(where: { $0.source == "system" })?.end ?? 0
        return ordered.filter { $0.source != "microphone" || $0.end <= systemEnd + EchoFilter.Policy().slack }
    }
}
