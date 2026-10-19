import Foundation

/// A sidecar ledger in the ephemeral meeting store, never hidden IDs in the Markdown.
public struct NoteDocument: Codable, Equatable, Sendable {
    public struct Owned: Codable, Equatable, Sendable {
        public var from: Int; public var to: Int; public var text: String
        public init(from: Int, to: Int, text: String) { self.from = from; self.to = to; self.text = text }
    }
    public struct Block: Codable, Equatable, Sendable {
        public var id: String; public var from: Int; public var to: Int; public var text: String
        public var at: Double?; public var section: String?; public var owned: Owned?
        public var images: [NoteImage]?
        public var surface: String?
        public init(id: String, from: Int, to: Int, text: String, at: Double? = nil, section: String? = nil, owned: Owned? = nil, images: [NoteImage]? = nil) {
            self.id = id; self.from = from; self.to = to; self.text = text; self.at = at; self.section = section; self.owned = owned; self.images = images
        }
    }
    public var path: String; public var source: String; public var revision: Int; public var blocks: [Block]
    public struct Insertion: Codable, Equatable, Sendable {
        public var at: Int; public var text: String
        public init(at: Int, text: String) {self.at=at;self.text=text}
    }
    public var insertions: [Insertion]?
    public var finalized: Bool?
    public init(path: String, source: String, revision: Int = 0, blocks: [Block] = [], finalized: Bool = false) {
        self.path = FileIdentity.path(path); self.source = source; self.revision = revision; self.blocks = blocks; self.finalized = finalized
    }
    public enum Failure: LocalizedError {
        case invalid, stale, changed, missing
        public var errorDescription: String? {
            switch self {
            case .invalid: "Invalid note block snapshot"
            case .stale: "The note changed in another editor. Reload before syncing."
            case .changed: "Your note has unsynced edits. Open it in Obsidian and finalize again."
            case .missing: "The meeting note is unavailable. Restore or reopen it before finalizing."
            }
        }
    }
    public func validate() throws {
        let s = source as NSString
        guard revision >= 0, blocks.count <= 2000, Set(blocks.map(\.id)).count == blocks.count else { throw Failure.invalid }
        var end = 0
        for b in blocks {
            guard !b.id.isEmpty, b.id.count <= 100, b.from >= end, b.to > b.from, b.to <= s.length,
                  s.substring(with: NSRange(location: b.from, length: b.to - b.from)) == b.text,
                  b.at == nil || (b.at!.isFinite && b.at! >= 0) else { throw Failure.invalid }
            end = b.to
            if let o = b.owned {
                guard o.from >= end, o.to >= o.from, o.to <= s.length,
                      !o.text.isEmpty, s.substring(with: NSRange(location: o.from, length: o.to - o.from)) == o.text else { throw Failure.invalid }
                end = o.to
            }
        }
    }
    /// An authoritative full sync: deletion/reorder are implicit and idempotent; no per-keystroke requests.
    public func notes(previous: [Note], at: Double? = nil) -> [Note] {
        let old = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return blocks.map { b in
            var n = old[b.id] ?? Note(text: b.text, createdAt: b.at)
            n.id = b.id
            if n.text != b.text || n.section != b.section { n.editText(b.text, at: at) }
            n.section = b.section
            n.surface = b.surface
            let targets = NoteImageContent.parse(b.text, source: source).targets
            let images = targets.prefix(8).map { target -> NoteImage in
                let path = b.images?.first { $0.target == target }?.path
                return n.images?.first { $0.target == target && $0.path == path } ?? NoteImage(target: target, path: path)
            }
            if (n.images ?? []) != images {
                n.images = images; n.line.queryText = nil; n.line.state = n.line.owned == true ? .yours : .listening
                if n.line.owned != true { n.line.text = nil }
            }
            // Minor edits keep typing time; a changed subject starts a new moment window.
            if let owned = b.owned {
                let text = owned.text.components(separatedBy: "\n").map { $0.hasPrefix("> ") ? String($0.dropFirst(2)) : ($0.hasPrefix(">") ? String($0.dropFirst()) : $0) }.joined(separator: "\n")
                if n.line.owned != true || n.line.text != text { n.editEnhancement(.init(topic: "", text: text)) }
            } else if n.line.owned == true { n.letAIRewrite() }
            return n
        }
    }
    /// Deadline recovery when Obsidian was closed: only exact, unique, line-aligned blocks keep AI.
    /// Ambiguous/edited/deleted blocks are omitted from insertion, never guessed or rewritten.
    public func rebased(on current: String) -> NoteDocument {
        let text = current as NSString
        var result = self; result.source = current; result.blocks = []
        for block in blocks {
            var found: [NSRange] = [], search = NSRange(location: 0, length: text.length)
            while search.length > 0 {
                let hit = text.range(of: block.text, options: [], range: search)
                if hit.location == NSNotFound { break }
                let end = NSMaxRange(hit)
                if (hit.location == 0 || text.character(at: hit.location - 1) == 10) &&
                   (end == text.length || text.character(at: end) == 10) { found.append(hit) }
                search = NSRange(location: end, length: text.length - end)
            }
            guard found.count == 1 else { continue }
            var next = block; next.from = found[0].location; next.to = NSMaxRange(found[0])
            if let owned = block.owned {
                let suffix = NSRange(location: next.to, length: text.length - next.to)
                let hit = text.range(of: owned.text, options: [], range: suffix)
                guard hit.location != NSNotFound,
                      text.substring(with: NSRange(location: next.to, length: hit.location-next.to)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                next.owned = .init(from: hit.location, to: NSMaxRange(hit), text: owned.text)
            }
            result.blocks.append(next)
        }
        result.blocks.sort { $0.from < $1.from }
        return result
    }

    public static func quote(_ text: String) -> String {
        text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
    }
    /// Inserts only between blocks. All original UTF-16 code units retain their order and contents.
    public func finalizedInsertions(meeting: Meeting) throws -> [Insertion] {
        try validate()
        let notes = Dictionary((meeting.notes ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var inserts: [Insertion] = []
        if source.contains("\nworkscribe:"), !source.contains("\nduration:"), let ended=meeting.endedAt,
           let tag=source.range(of:"\ntags:") {
            let at=(source as NSString).range(of:String(source[..<tag.upperBound])).length-5
            var metadata="duration: \(max(1,Int((ended.timeIntervalSince(meeting.startedAt)/60).rounded()))) min\n"
            if let names=meeting.attendees,!names.isEmpty,!source.contains("\nattendees:") {
                metadata += "attendees:\n" + names.map { "  - \"[[" + $0.replacingOccurrences(of:"\"",with:"\\\"") + "]]\"" }.joined(separator:"\n") + "\n"
            }
            inserts.append(.init(at:at,text:metadata))
        }

        for block in blocks {
            guard block.owned == nil, let enhanced=notes[block.id]?.line.text, !enhanced.isEmpty else {continue}
            inserts.append(.init(at:block.to,text:"\n" + Self.continuation(NoteEnhancementText(markdown: enhanced).text,block:block.text)))
        }
        if let brief=meeting.brief, !brief.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            var start=0
            var separator=""
            if source.hasPrefix("---\n"), let range=source.range(of:"\n---\n",range:source.index(source.startIndex,offsetBy:4)..<source.endIndex) {
                start=(source as NSString).range(of:String(source[..<range.upperBound])).length
                if (source as NSString).length>start && (source as NSString).character(at:start)==10 {start+=1} else {separator="\n"}
            }
            inserts.append(.init(at:start,text:separator + "*" + Self.escapeEmphasis(brief.replacingOccurrences(of:"\n",with:" ")) + "*\n\n"))
        }
        var tail = ""
        if let missed = meeting.missedTopics, !missed.isEmpty {
            tail += "\n\n## Also discussed\n\n" + missed.map { "- *" + Self.escapeEmphasis($0.topic.hasSuffix(".") ? $0.topic : $0.topic + ".") + " " + Self.escapeEmphasis($0.text) + "*" }.joined(separator: "\n") + "\n"
        }
        let existing = Set(source.components(separatedBy: .newlines).compactMap { line in OpenItems.actionText(line) ?? (line.range(of:#"^\s*[-*] \[[xX]\] "#,options:.regularExpression).map {String(line[$0.upperBound...])}) }.map(Self.normalizedTask))
        var seen = existing
        let actions = (meeting.actionItems ?? []).filter { seen.insert(Self.normalizedTask($0.text)).inserted }
        if !actions.isEmpty {
            tail += (tail.isEmpty ? "\n\n" : "\n") + "## Action items\n\n" + actions.map { item in
                "- [ ] " + (item.owner.map { "[[" + $0 + "]] " } ?? "") + Self.escapeEmphasis(item.text.replacingOccurrences(of: "\n", with: " ")) + (item.due.map { " 📅 " + $0 } ?? "")
            }.joined(separator: "\n") + "\n"
        }
        if !tail.isEmpty {
            // One blank line after the existing final newline; preserve user whitespace.
            if source.hasSuffix("\n") && tail.hasPrefix("\n") {tail.removeFirst()}
            inserts.append(.init(at:(source as NSString).length,text:tail))
        }
        return inserts.sorted {$0.at < $1.at}
    }
    public func finalizedText(meeting: Meeting) throws -> String {
        let text=NSMutableString(string:source)
        for insertion in try finalizedInsertions(meeting:meeting).reversed() {text.insert(insertion.text,at:insertion.at)}
        return text as String
    }
    public static func normalizedTask(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[\[[^\]]+\]\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"📅 \d{4}-\d{2}-\d{2}"#, with: "", options: .regularExpression)
            .lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    public static func escapeEmphasis(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "_", with: "\\_")
    }
    public static func continuation(_ text: String, block: String) -> String {
        let line = block.components(separatedBy: "\n").first ?? block
        let pattern = "^(\\s*)(?:[-+*]|[0-9]+[.)])\\s+"
        let match = line.range(of: pattern, options: .regularExpression)
        let indent = match.map { String(repeating: " ", count: line.distance(from: line.startIndex, to: $0.upperBound)) } ?? ""
        return text.components(separatedBy: "\n").map { indent + "*" + escapeEmphasis($0) + "*" }.joined(separator: "\n")
    }
}
