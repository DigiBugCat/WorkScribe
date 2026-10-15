import Foundation

/// A frontmatter value: Obsidian properties are flat, so a scalar or a list of scalars covers what we read and write.
public enum YAMLValue: Equatable, Sendable {
    case string(String)
    case list([String])

    public var strings: [String] {
        switch self {
        case .string(let value): value.isEmpty ? [] : [value]
        case .list(let values): values
        }
    }
    public var first: String? { strings.first }
}

/// Flat YAML frontmatter (`key: value`, `key:` + `- item` lists, `[a, b]` inline lists, quoted scalars, block scalars).
/// Not a YAML implementation: nested maps are read as their raw text and anything unreadable is skipped, never fatal.
public struct Frontmatter: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var key: String
        public var value: YAMLValue
        public init(_ key: String, _ value: YAMLValue) { self.key = key; self.value = value }
    }
    public var entries: [Entry]
    public init(_ entries: [Entry] = []) { self.entries = entries }

    public subscript(key: String) -> YAMLValue? {
        get { entries.first { $0.key == key }?.value }
        set {
            if let index = entries.firstIndex(where: { $0.key == key }) {
                if let newValue { entries[index].value = newValue } else { entries.remove(at: index) }
            } else if let newValue { entries.append(Entry(key, newValue)) }
        }
    }
    public var keys: [String] { entries.map(\.key) }

    /// Splits `---` frontmatter from the body. The YAML excludes the fences; the body starts after the closing fence.
    public static func split(_ text: String) -> (yaml: String?, body: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return (nil, normalized) }
        var lines = normalized.components(separatedBy: "\n")
        lines.removeFirst()
        guard let close = lines.firstIndex(where: { $0 == "---" || $0 == "..." }) else { return (nil, normalized) }
        let yaml = lines[..<close].joined(separator: "\n")
        let body = lines[(close + 1)...].joined(separator: "\n")
        return (yaml, body)
    }

    public static func parse(_ yaml: String) -> Frontmatter {
        var out = Frontmatter()
        let lines = yaml.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            guard let first = line.first, first != " ", first != "\t", first != "#", first != "-",
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // Indented continuation lines belong to this key.
            var block: [String] = []
            while index < lines.count, let next = lines[index].first, next == " " || next == "\t" || lines[index].hasPrefix("- ") || lines[index] == "-" {
                block.append(lines[index]); index += 1
            }
            if rest.isEmpty {
                let items = block.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if !items.isEmpty, items.allSatisfy({ $0.hasPrefix("-") }) {
                    out.entries.append(Entry(key, .list(items.map { unquote(String($0.dropFirst()).trimmingCharacters(in: .whitespaces)) })))
                } else {
                    out.entries.append(Entry(key, .string(items.joined(separator: "\n"))))
                }
            } else if rest == "|" || rest == ">" || rest.hasPrefix("|") || rest.hasPrefix(">") {
                let text = block.map { $0.trimmingCharacters(in: .whitespaces) }
                out.entries.append(Entry(key, .string(text.joined(separator: rest.hasPrefix(">") ? " " : "\n"))))
            } else if rest.hasPrefix("["), rest.hasSuffix("]"), !rest.hasPrefix("[[") || rest.hasPrefix("[[[") {
                out.entries.append(Entry(key, .list(inlineList(String(rest.dropFirst().dropLast())))))
            } else {
                out.entries.append(Entry(key, .string(unquote(stripComment(rest)))))
            }
        }
        return out
    }

    static func stripComment(_ value: String) -> String {
        guard !value.hasPrefix("\""), !value.hasPrefix("'"), let range = value.range(of: " #") else { return value }
        return String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    static func inlineList(_ text: String) -> [String] {
        var items: [String] = [], current = "", quote: Character?, depth = 0
        for character in text {
            if let open = quote {
                current.append(character)
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" { quote = character; current.append(character) }
            else if character == "[" { depth += 1; current.append(character) }
            else if character == "]" { depth -= 1; current.append(character) }
            else if character == ",", depth == 0 { items.append(current); current = "" }
            else { current.append(character) }
        }
        items.append(current)
        return items.map { unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
    }

    static func unquote(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            var out = "", escaping = false
            for character in value.dropFirst().dropLast() {
                if escaping {
                    switch character {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    default: out.append(character)
                    }
                    escaping = false
                } else if character == "\\" { escaping = true } else { out.append(character) }
            }
            return out
        }
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return value
    }

    // MARK: Writing

    public func render() -> String {
        entries.map { entry in
            switch entry.value {
            case .string(let value): "\(entry.key): \(Self.scalar(value))"
            case .list(let values):
                values.isEmpty ? "\(entry.key): []" : (["\(entry.key):"] + values.map { "  - \(Self.scalar($0))" }).joined(separator: "\n")
            }
        }.joined(separator: "\n")
    }

    /// A scalar, double-quoted when plain YAML would read it as something else (a link list, a time, a comment…).
    public static func scalar(_ value: String) -> String {
        guard needsQuotes(value) else { return value }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    static func needsQuotes(_ value: String) -> Bool {
        if value.isEmpty || value != value.trimmingCharacters(in: .whitespaces) { return true }
        if value.contains(": ") || value.contains(" #") || value.contains("\n") || value.contains("\t") || value.hasSuffix(":") { return true }
        if let first = value.first, "[]{}#&*!|>'\"%@`,?-:".contains(first) { return true }
        if ["true", "false", "yes", "no", "null", "~", "on", "off"].contains(value.lowercased()) { return true }
        // 10:02 is a base-60 integer to YAML 1.1 readers.
        if value.range(of: #"^\d+(:\d+)+$"#, options: .regularExpression) != nil { return true }
        return false
    }
}
