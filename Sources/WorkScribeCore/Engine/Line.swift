import Foundation

/// Durable state belongs to the generated line, never to the user's words.
public struct Line: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case listening, found, answered, settled, quiet, yours }
    public var state: State = .listening
    public var text: String?
    public var queryText: String?
    public var revision: Int? = 0
    public var evidence: [String]?
    public var basis: String?
    public var seenThrough: Int64 = 0
    public var attemptedEvidence: [String]?
    public var updatedAt: Date?
    public var history: [LineRevision] = []
    public init() {}
    public var owned: Bool? {
        get { state == .yours }
        set { if newValue == true { takeOwnership() } else if state == .yours { state = text == nil ? .listening : .answered } }
    }
    public mutating func reset() { guard state != .yours else { return }; let next = (revision ?? 0) + 1; self = Line(); revision = next }
    public mutating func takeOwnership() { state = .yours; revision = (revision ?? 0) + 1 }
    public mutating func resume() { if state == .settled || state == .quiet { state = text == nil ? .listening : .answered } }
    public mutating func settle() { guard state != .yours else { return }; state = text == nil ? .quiet : .settled }
    public mutating func retract(remaining: [String], jot: String) {
        guard state != .yours, let text else { return }
        if remaining.isEmpty || !LineFaithfulness.grounded(NoteEnhancementText(markdown: text).text, evidence: remaining, jot: jot) { reset() }
    }
    @discardableResult public mutating func apply(_ outcome: LineOutcome, basis: String, query: String, at: Date) -> Bool {
        guard state != .yours else { return false }
        self.basis = basis
        switch outcome {
        case .line(let bullet, let ids):
            guard text != bullet.markdown, !history.contains(where: { $0.text == bullet.markdown }) else { return false }
            revision = (revision ?? 0) + 1; text = bullet.markdown; evidence = ids; queryText = query
            state = .answered; updatedAt = at
            history.append(LineRevision(version: revision ?? 1, text: bullet.markdown, reason: history.isEmpty ? "First matching discussion" : "New evidence", at: at, evidence: ids))
            return true
        case .quiet, .unchanged: state = text == nil ? .listening : .answered; return false
        }
    }
}

public struct LineRevision: Codable, Equatable, Sendable {
    public var version: Int
    public var text: String
    public var reason: String
    public var at: Date
    public var evidence: [String]
    public init(version: Int, text: String, reason: String, at: Date, evidence: [String]) {
        self.version = version; self.text = text; self.reason = reason; self.at = at; self.evidence = evidence
    }
}

public enum LineRejection: String, Codable, Sendable, CaseIterable {
    case format, tooShort, unsupported, abstained, modelError, topicMixing, modality, numericConflict, attribution, superseded, absence, joke, factsLost, cosmetic, flap
}
extension LineRejection {
    public var correction: String? {
        switch self {
        case .unsupported: "Omit unsupported numbers. Use only quantities in this jot's evidence."
        case .modality: "Keep the claim tentative or conditional where its supporting statement is tentative."
        case .numericConflict: "A quantity conflicts with another mention. Use an explicit correction; otherwise omit it."
        case .attribution: "Remove names unless that exact statement is explicitly attributed. Preserve who tells whom."
        case .superseded: "Use the latest decision; keep reopened questions open."
        case .absence: "Remove invented unknowns or absence claims. State only what the evidence supports."
        case .joke: "Omit jokes and exaggerated quantities."
        case .format, .tooShort: "Use exactly * **Topic:** followed by an 8–45-word answer, or NOT DISCUSSED."
        default: nil
        }
    }
}
public enum LineOutcome: Equatable, Sendable {
    case line(Bullet, [String]), unchanged, quiet(LineRejection)
}

public enum LineCheck {
    /// A short answer names what the jot asked about ("Team is $20" for "what's the Team price?"), so it can't
    /// be an unrelated fact that happens to be short ("Training stays Thursday" for "dry run when?").
    public static func about(_ answer: String, jot: String) -> Bool {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 })
        }
        let common: Set<String> = ["the", "and", "what", "when", "who", "how", "much", "many", "does", "did", "for", "with", "this", "that", "are", "was", "is"]
        return !words(answer).intersection(words(jot)).subtracting(common).isEmpty
    }
    /// A number, amount, date or name: something a short answer can be checked against.
    public static func concrete(_ text: String) -> Bool {
        if text.rangeOfCharacter(from: CharacterSet.decimalDigits.union(CharacterSet(charactersIn: "$€£¥%"))) != nil { return true }
        let words = text.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        let calendar = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november",
                        "december", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "today", "tomorrow"]
        if words.contains(where: { calendar.contains($0.lowercased()) }) { return true }
        return words.dropFirst().contains { $0.first?.isUppercase == true }
    }
    /// `allowShort` admits a 3–7-word line that carries a concrete fact ("Team is $20."). The engine asks for
    /// a fuller line first and only falls back to the short one when the model gives nothing longer.
    public static func accept(_ output: String, request: LineRequest, evidence: [PromptEvidence], allowShort: Bool = false) -> LineOutcome {
        guard Set(evidence.map(\.id)).isSubset(of: Set(request.refs)) else { return .quiet(.topicMixing) }
        let raw = output.replacingOccurrences(of: NotePrompt.endMarker, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.uppercased() == "UNCHANGED" { return .unchanged }
        if raw.uppercased() == "NOT DISCUSSED" { return .quiet(.abstained) }
        var parsed = NoteOutput.parse(output)
        // A sole labelled sentence is the same line shape; Markdown punctuation is not a faithfulness test.
        if parsed.notes.isEmpty, parsed.missed.isEmpty, !raw.contains("\n"),
           matches(raw, #"^[\p{L}\p{N}][\p{L}\p{N} '’/?!()–—-]{0,59}:\s+\S"#) {
            parsed = NoteOutput.parse("* " + raw)
        }
        guard parsed.notes.count == 1, parsed.missed.isEmpty, var bullet = parsed.notes.first, NoteOutput.usable(bullet) else { return .quiet(.format) }
        let count = bullet.text.split(whereSeparator: \.isWhitespace).count
        // A sentence that trails off ("Finance signs off by…") states nothing yet.
        if bullet.text.trimmingCharacters(in: .whitespaces).hasSuffix("…") || bullet.text.trimmingCharacters(in: .whitespaces).hasSuffix("...") {
            return .quiet(.abstained)
        }
        // A direct question's best answer can be short ("Team is $20."); grounding below must still find it.
        let short = allowShort && count >= EngineConstants.lineShortWords && LineCheck.concrete(bullet.text)
            && LineCheck.about(bullet.text, jot: request.note.shorthand)
        guard count >= EngineConstants.lineMinimumWords || short, count <= EngineConstants.lineWords else { return .quiet(.tooShort) }
        bullet = NoteOutput.withoutPlaceholder(bullet)
        if bullet.topic.isEmpty { bullet.topic = request.note.shorthand.trimmingCharacters(in: CharacterSet(charactersIn: "? ")) }
        bullet.topic = spellingLock(bullet.topic, jot: request.note.shorthand)
        bullet.text = spellingLock(Grounding.tidy(bullet.text), jot: request.note.shorthand)
        let support = evidence.map(\.chunk.text) + [request.note.imageEvidence].filter { !$0.isEmpty }
        guard LineFaithfulness.grounded(bullet.text, evidence: support, jot: request.note.shorthand) else { return .quiet(.unsupported) }

        if request.backgroundOnly, request.note.createdAt != nil, let source = request.background.first {
            bullet.text += " (from *\(source.title)*)"
            guard bullet.text.split(whereSeparator: \.isWhitespace).count <= EngineConstants.lineWords else { return .quiet(.format) }
        }
        if let previous = request.previous {
            let old = NoteEnhancementText(markdown: previous)
            bullet.topic = old.topic.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            if NoteEnhancementText(markdown: previous).text == bullet.text { return .unchanged }
        }
        guard !request.note.line.history.contains(where: { $0.text == bullet.markdown }) else { return .quiet(.flap) }
        return .line(bullet, evidence.map { $0.chunk.id })
    }
    public static func facts(_ text: String) -> Set<String> {
        var result = Set(Grounding.numbers(in: text).map { "number:\($0)" })
        let pattern = #"\b[A-Z][a-zA-Z]{2,}\b|(?i:\b(?:agreed|decided|approved|proposed|at risk|blocked|open|pending|moved|delayed|cancelled|shipped|may|might|could|tentative|reopened)\b)"#
        result.formUnion(captures(text, pattern).map { $0.lowercased() })
        return result
    }
    static func matches(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
    static func captures(_ text: String, _ pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
    public static func spellingLock(_ text: String, jot: String) -> String {
        let terms = captures(jot, #"\b[A-Za-z][A-Za-z0-9]{2,}\b"#)
        var result = text
        for word in captures(text, #"\b[A-Za-z][A-Za-z0-9]{2,}\b"#) where word.first?.isUppercase == true {
            guard let term = terms.first(where: { $0 != word && ((word == word.uppercased() && $0.lowercased() == word.lowercased()) || ($0.first?.isUppercase == true && distance($0.lowercased(), word.lowercased()) <= 2)) }) else { continue }
            result = result.replacingOccurrences(of: "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b", with: term, options: .regularExpression)
        }
        return result
    }
    static func distance(_ a: String, _ b: String) -> Int {
        var row = Array(0...b.count); let letters = Array(b)
        for (i, x) in a.enumerated() { var next = [i + 1]; for (j, y) in letters.enumerated() { next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (x == y ? 0 : 1))) }; row = next }
        return row.last ?? 0
    }
}
extension SearchIndex {
    static let linesTable = "CREATE TABLE IF NOT EXISTS lines(source TEXT NOT NULL, query TEXT NOT NULL, json TEXT NOT NULL, PRIMARY KEY(source, query))"
    public func saveLines(_ meeting: Meeting) throws {
        try db.transaction {
            guard try meta("purged:" + meeting.id) != "1" else { return }
            try db.run("DELETE FROM lines WHERE source=?", [.text(meeting.id)])
            for note in meeting.notes ?? [] {
                let data = try JSONEncoder().encode(note.line)
                try db.run("INSERT INTO lines(source,query,json) VALUES(?,?,?)", [.text(meeting.id), .text(note.id), .text(String(decoding: data, as: UTF8.self))])
            }
        }
    }
    public func line(source: String, query: String) throws -> Line? {
        guard let json = try db.scalar("SELECT json FROM lines WHERE source=? AND query=?", [.text(source), .text(query)]) else { return nil }
        return try JSONDecoder().decode(Line.self, from: Data(json.utf8))
    }
}
