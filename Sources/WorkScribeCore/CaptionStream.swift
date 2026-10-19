import Foundation

/// Turns repeated looks at a meeting platform's live captions into the same transcript events the
/// speech recognizer produces, so everything downstream treats captions like speech.
///
/// Platforms show captions as blocks: a speaker's name and a paragraph that grows while they talk
/// (its last words are sometimes revised). A pause starts a new block, and older blocks stay on screen
/// until they scroll away. Each block is tracked by its opening words. Words become a final segment
/// once the block stops changing for `settle` seconds, or after `longest` seconds of continuous
/// growth; words already finalized are never emitted again, however long the block stays visible.
public struct CaptionStream {
    /// One caption block as it appears on screen right now.
    public struct Look: Equatable {
        public var speaker: String?
        public var text: String
        /// The block's opening scrolled out of view: this is the rest of a block already seen.
        public var continued: Bool
        public init(speaker: String?, text: String, continued: Bool = false) {
            self.speaker = speaker; self.text = text; self.continued = continued
        }
    }

    /// Seconds without a change before words are final (docs/specs/making-your-own.md §2.4).
    public var settle = 1.5
    /// No single segment runs longer than this.
    public var longest = 30.0
    /// Captions trail speech; words are stamped this much earlier than first seen.
    public var latency = 1.0

    /// Display names in order of first appearance; speaker `n` is `names[n - 1]`.
    public private(set) var names: [String] = []

    private struct Block {
        /// Normalized words, compared on the opening.
        var key: [String]
        var speaker: String?
        var words: [String]
        var committed = 0
        var pendingSince: Double
        var changed: Double
        var seen: Double
    }
    private var blocks: [Block] = []
    /// Four-word runs of the transcript written before a resume, and until when to check against them.
    private var known: Set<[String]> = []
    private var knownUntil = -1.0

    public init() {}

    /// Resuming a meeting: captions still on screen were already transcribed. Blocks that appear in the
    /// next few seconds skip the words `transcript` already holds and continue from there.
    public mutating func prime(with transcript: String, at: Double) {
        known = Self.grams(Self.tokens(transcript).suffix(1500).map(Self.normal))
        knownUntil = at + 10
    }

    /// Feed every caption block currently on screen (top to bottom), seen `at` seconds into the meeting.
    public mutating func observe(_ looks: [Look], at: Double) -> [[String: Any]] {
        var events: [[String: Any]] = []
        var matched = Set<Int>()
        for look in looks {
            let words = Self.tokens(look.text)
            guard !words.isEmpty else { continue }
            if let name = look.speaker, !name.isEmpty, !names.contains(name) { names.append(name) }
            let key = words.map(Self.normal)
            let current = blocks
            let open = current.indices.filter { !matched.contains($0)
                && (look.speaker == nil || current[$0].speaker == nil || current[$0].speaker == look.speaker) }
            // Platforms trim old text from the front: the box scrolls (Zoom while sharing) or the list keeps
            // only so much (Zoom's caption panel). A look made mostly of a known block's words is that block
            // with its opening cut off, whatever its first words now are.
            let grams = Self.grams(key)
            var candidates: [(index: Int, cover: Double)] = open.map { ($0, Self.cover(grams, current[$0].key)) }
            if !look.continued { candidates.removeAll { $0.cover < 0.6 } }
            candidates.sort { $0.cover != $1.cover ? $0.cover > $1.cover : $0.index > $1.index }
            var trimmed: (Int, [String])?
            for candidate in candidates {
                if let joined = Self.rejoin(current[candidate.index].words, words) { trimmed = (candidate.index, joined); break }
            }
            if let (index, words) = trimmed, look.continued || !Self.sameBlock(current[index].key, key) {
                matched.insert(index)
                blocks[index].seen = at
                if words.count >= blocks[index].committed, words != blocks[index].words {
                    if blocks[index].words.count <= blocks[index].committed { blocks[index].pendingSince = at }
                    blocks[index].words = words; blocks[index].key = words.map(Self.normal); blocks[index].changed = at
                    if words.count > blocks[index].committed { events.append(partial(blocks[index])) }
                }
                continue
            }
            // A cut-off tail with nothing to anchor it to stays quiet, unless it is the first thing seen
            // (the meeting was joined part way through).
            if look.continued, !blocks.isEmpty, trimmed == nil { continue }
            // A block that just appeared can still have its first words revised ("Fine, No" → "Fine, November 4th").
            // Several blocks can open the same way; the one sharing most words wins, the latest on a tie.
            let index = open.filter { Self.sameBlock(current[$0].key, key) }.reversed().max { Self.cover(grams, current[$0].key) < Self.cover(grams, current[$1].key) }
                ?? open.last { current[$0].committed == 0 && at - current[$0].changed < settle && current[$0].key.first == key.first }
            if let index {
                matched.insert(index)
                blocks[index].key = key; blocks[index].seen = at
                if words != blocks[index].words {
                    if blocks[index].words.count <= blocks[index].committed { blocks[index].pendingSince = at }
                    blocks[index].words = words; blocks[index].changed = at
                    if words.count > blocks[index].committed { events.append(partial(blocks[index])) }
                }
            } else {
                matched.insert(blocks.count)
                var block = Block(key: key, speaker: look.speaker, words: words, pendingSince: at, changed: at, seen: at)
                if at <= knownUntil { block.committed = Self.alreadyWritten(key, known) }
                blocks.append(block)
                if block.words.count > block.committed { events.append(partial(block)) }
            }
        }
        for i in blocks.indices where blocks[i].words.count > blocks[i].committed {
            if at - blocks[i].changed >= settle || at - blocks[i].pendingSince >= longest { events.append(finish(i, at: at)) }
        }
        blocks.removeAll { at - $0.seen > 120 && $0.committed >= $0.words.count }
        return events
    }

    /// Ends the meeting: whatever is on screen becomes final.
    public mutating func flush(at: Double) -> [[String: Any]] {
        blocks.indices.filter { blocks[$0].words.count > blocks[$0].committed }.map { finish($0, at: at) }
    }

    private func pending(_ block: Block) -> [String] { Array(block.words.dropFirst(block.committed)) }

    private func partial(_ block: Block) -> [String: Any] {
        var event: [String: Any] = ["type": "transcript.partial", "transcript": pending(block).joined(separator: " ")]
        if let id = speakerID(block) { event["speaker"] = id }
        return event
    }

    private func speakerID(_ block: Block) -> Int? { block.speaker.flatMap { names.firstIndex(of: $0) }.map { $0 + 1 } }

    private mutating func finish(_ i: Int, at: Double) -> [String: Any] {
        let words = pending(blocks[i])
        let start = max(0, blocks[i].pendingSince - latency)
        let end = max(start + 0.2, min(at, blocks[i].changed + 0.5) - latency)
        let step = (end - start) / Double(max(words.count, 1))
        let id = speakerID(blocks[i]) ?? 0
        let timed: [[String: Any]] = words.enumerated().map { index, word in
            ["word": word, "speaker": id, "start": start + Double(index) * step, "end": start + Double(index + 1) * step]
        }
        blocks[i].committed = blocks[i].words.count
        blocks[i].pendingSince = at
        return ["type": "transcript.completed", "transcript": words.joined(separator: " "), "words": timed]
    }

    /// The same block seen again: it opens with the same words (at least three, or all of a shorter one).
    /// The platform may still revise words after the opening.
    static func sameBlock(_ a: [String], _ b: [String]) -> Bool {
        let shared = zip(a, b).prefix { $0 == $1 }.count
        return shared >= min(3, a.count, b.count) && shared > 0
    }
    /// How many opening words of a block the transcript already holds: up to the last of its four-word
    /// runs found there, tolerating a few words the platform revised since.
    static func alreadyWritten(_ words: [String], _ known: Set<[String]>) -> Int {
        guard words.count >= 4, !known.isEmpty else { return 0 }
        var written = 0, misses = 0
        for start in 0...(words.count - 4) {
            if known.contains(Array(words[start..<(start + 4)])) { written = start + 4; misses = 0 }
            else { misses += 1; if misses > 3 { break } }
        }
        return written
    }
    /// Every run of four words, for telling which block a look belongs to.
    static func grams(_ words: [String]) -> Set<[String]> {
        words.count < 4 ? [] : Set((0...(words.count - 4)).map { Array(words[$0..<($0 + 4)]) })
    }
    /// Share of the look's four-word runs that the block already contains.
    static func cover(_ grams: Set<[String]>, _ block: [String]) -> Double {
        grams.isEmpty ? 0 : Double(grams.intersection(Self.grams(block)).count) / Double(grams.count)
    }
    /// `visible` is the end of `known` with its opening cut off: the known opening followed by the visible
    /// words, anchored on a run of four words they share. Nil when no anchor is found.
    static func rejoin(_ known: [String], _ visible: [String]) -> [String]? {
        let a = known.map(normal), b = visible.map(normal)
        let run = min(4, b.count)
        guard run > 0, a.count >= run else { return nil }
        for start in 0...min(8, b.count - run) {
            let anchor = Array(b[start..<(start + run)])
            guard let at = (0...(a.count - run)).last(where: { Array(a[$0..<($0 + run)]) == anchor }), at >= start else { continue }
            // Past the anchor the two must still mostly agree, or this is another block sharing a phrase.
            let shared = min(a.count - at, b.count - start)
            guard zip(a[at...], b[start...]).filter({ $0 == $1 }).count * 5 >= shared * 4 else { continue }
            return Array(known[0..<(at - start)]) + visible
        }
        return nil
    }
    static func tokens(_ text: String) -> [String] { text.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
    static func normal(_ word: String) -> String { word.lowercased().trimmingCharacters(in: .punctuationCharacters) }
}
