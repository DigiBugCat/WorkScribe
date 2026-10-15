import Foundation

/// `[[target#heading|alias]]`, `[[target#^block]]`, or with a leading `!`, an embed.
public struct WikiLink: Equatable, Sendable {
    public var target: String
    public var heading: String?
    public var block: String?
    public var alias: String?
    public var embed: Bool
    public init(target: String, heading: String? = nil, block: String? = nil, alias: String? = nil, embed: Bool = false) {
        self.target = target; self.heading = heading; self.block = block; self.alias = alias; self.embed = embed
    }
    /// What the link reads as in text.
    public var display: String {
        if let alias, !alias.isEmpty { return alias }
        let name = target.split(separator: "/").last.map(String.init) ?? target
        return [name, heading].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " › ")
    }
}

public struct MarkdownLink: Equatable, Sendable {
    public var text: String
    public var url: String
    public var image: Bool
}

public struct MarkdownTask: Equatable, Sendable {
    public var text: String
    public var done: Bool
    /// `📅 2026-10-16` (Tasks) or `due:: 2026-10-16` (Dataview).
    public var due: String?
    public var line: Int
}

public struct Callout: Equatable, Sendable {
    public var type: String
    public var title: String
    public var text: String
}

public struct MarkdownSection: Equatable, Sendable {
    /// Nil for text before the first heading.
    public var heading: String?
    public var level: Int
    /// Plain text: links read as their display text, markup and comments removed.
    public var text: String
    public var line: Int
}

/// A vault note read structurally: frontmatter, links, embeds, highlights, callouts, tasks, tags, block ids and
/// heading sections with their plain text. Code fences are kept as text but never scanned for syntax; unknown syntax
/// stays as text. Embeds are listed, not resolved (the indexer resolves them one level deep).
public struct VaultDocument: Equatable, Sendable {
    public var frontmatter = Frontmatter()
    public var title: String?
    public var links: [WikiLink] = []
    public var urls: [MarkdownLink] = []
    public var highlights: [String] = []
    public var callouts: [Callout] = []
    public var tasks: [MarkdownTask] = []
    public var tags: [String] = []
    public var blockIDs: [String] = []
    public var sections: [MarkdownSection] = []

    public var embeds: [WikiLink] { links.filter(\.embed) }
    public var plainText: String {
        sections.map { [$0.heading, $0.text].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "\n") }
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Frontmatter tags plus inline `#tags`, without the `#`, deduplicated in order.
    public var allTags: [String] {
        var seen = Set<String>()
        let front = (frontmatter["tags"]?.strings ?? []) + (frontmatter["tag"]?.strings ?? [])
        return (front.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 } + tags).filter { seen.insert($0.lowercased()).inserted }
    }

    public static func parse(_ text: String) -> VaultDocument {
        var document = VaultDocument()
        let (yaml, body) = Frontmatter.split(text)
        if let yaml { document.frontmatter = Frontmatter.parse(yaml) }
        let lines = Markdown.removingComments(body).components(separatedBy: "\n")

        var section = MarkdownSection(heading: nil, level: 0, text: "", line: 0)
        var sectionLines: [String] = []
        var fence: String?
        var callout: Callout?
        func flushCallout() {
            if let done = callout { document.callouts.append(done); callout = nil }
        }
        func flushSection() {
            section.text = sectionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if section.heading != nil || !section.text.isEmpty { document.sections.append(section) }
            sectionLines = []
        }

        for (number, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil } else { sectionLines.append(line) }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushCallout()
                fence = String(trimmed.prefix(3))
                continue
            }
            if let heading = Markdown.match(#"^(#{1,6})\s+(.*?)\s*#*\s*$"#, trimmed) {
                flushCallout(); flushSection()
                var title = heading[2] ?? ""
                if let block = Markdown.match(#"\s\^([A-Za-z0-9-]+)$"#, title) {
                    document.blockIDs.append(block[1] ?? ""); title = String(title.dropLast((block[0] ?? "").count))
                }
                scanInline(title, into: &document)
                let plain = Markdown.plain(title)
                section = MarkdownSection(heading: plain, level: heading[1]?.count ?? 1, text: "", line: number)
                if section.level == 1, document.title == nil { document.title = plain }
                continue
            }
            var content = line
            if trimmed.hasPrefix(">") {
                let inner = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if let head = Markdown.match(#"^\[!([A-Za-z][\w-]*)\][+-]?\s*(.*)$"#, inner) {
                    flushCallout()
                    callout = Callout(type: (head[1] ?? "note").lowercased(), title: Markdown.plain(head[2] ?? ""), text: "")
                    content = head[2] ?? ""
                } else {
                    if callout != nil {
                        callout!.text += (callout!.text.isEmpty ? "" : "\n") + Markdown.plain(inner)
                    }
                    content = inner
                }
            } else { flushCallout() }

            if let block = Markdown.match(#"\s\^([A-Za-z0-9-]+)\s*$"#, content) {
                document.blockIDs.append(block[1] ?? "")
                content = String(content.dropLast((block[0] ?? "").count))
            }
            if let task = Markdown.match(#"^\s*[-*+]\s+\[([ xX/\-])\]\s+(.*)$"#, content) {
                let body = task[2] ?? ""
                let due = Markdown.match(#"(?:📅|due::)\s*(\d{4}-\d{2}-\d{2})"#, body)?[1]
                document.tasks.append(MarkdownTask(text: Markdown.plain(body), done: (task[1] ?? " ").lowercased() == "x",
                                                   due: due, line: number))
            }
            scanInline(content, into: &document)
            sectionLines.append(Markdown.plain(content))
        }
        flushCallout(); flushSection()
        return document
    }

    static func scanInline(_ text: String, into document: inout VaultDocument) {
        for match in Markdown.all(Markdown.wikiLinkPattern, text) {
            let target = (match[2] ?? "").trimmingCharacters(in: .whitespaces)
            var heading: String?, block: String?
            if let anchor = match[3], anchor.count > 1 {
                let value = String(anchor.dropFirst())
                if value.hasPrefix("^") { block = String(value.dropFirst()) } else { heading = value }
            }
            let alias = match[4].map { String($0.dropFirst()) }
            document.links.append(WikiLink(target: target, heading: heading, block: block, alias: alias, embed: match[1] == "!"))
        }
        for match in Markdown.all(Markdown.markdownLinkPattern, text) {
            document.urls.append(MarkdownLink(text: Markdown.plain(match[2] ?? ""), url: match[3] ?? "", image: match[1] == "!"))
        }
        for match in Markdown.all(#"(?<!\\)==([^=\n]+?)=="#, text) {
            document.highlights.append(Markdown.plain(match[1] ?? ""))
        }
        // Tags need a non-digit; a URL fragment or heading marker isn't one.
        let withoutLinks = Markdown.replace(Markdown.markdownLinkPattern, in: Markdown.replace(Markdown.wikiLinkPattern, in: text, with: " "), with: " ")
        for match in Markdown.all(#"(?:^|\s)#([A-Za-z0-9_/\-]*[A-Za-z_/\-][A-Za-z0-9_/\-]*)"#, withoutLinks) {
            if let tag = match[1], !document.tags.contains(tag) { document.tags.append(tag) }
        }
    }
}

/// Regex and text helpers shared by the parser, the writer and the clip escaper.
public enum Markdown {
    // Backslash-escaped brackets (`\[`) are text, not syntax.
    static let wikiLinkPattern = #"(?<!\\)(!?)(?<!\\)\[\[([^\]\|#\n]*)(#[^\]\|\n]*)?(\|[^\]\n]*)?\]\]"#
    static let markdownLinkPattern = #"(?<!\\)(!?)(?<!\\)\[((?:[^\]\n\\]|\\.)*)\]\(<?([^)\s>]+)>?(?:\s+"[^"]*")?\)"#

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: NSRegularExpression] = [:]
    static func regex(_ pattern: String) -> NSRegularExpression {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached = cache[pattern] { return cached }
        let compiled = try! NSRegularExpression(pattern: pattern)
        cache[pattern] = compiled
        return compiled
    }

    /// The first match's groups (index 0 is the whole match), nil when it doesn't match.
    static func match(_ pattern: String, _ text: String) -> [String?]? { all(pattern, text, limit: 1).first }

    static func all(_ pattern: String, _ text: String, limit: Int = .max) -> [[String?]] {
        let ns = text as NSString
        var out: [[String?]] = []
        for result in regex(pattern).matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out.append((0..<result.numberOfRanges).map {
                let range = result.range(at: $0)
                return range.location == NSNotFound ? nil : ns.substring(with: range)
            })
            if out.count >= limit { break }
        }
        return out
    }

    static func replace(_ pattern: String, in text: String, with template: String) -> String {
        regex(pattern).stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }

    /// Drops `<!-- … -->` comments (WorkScribe's region markers among them) and `%% … %%` Obsidian comments.
    public static func removingComments(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #"(?s)<!--.*?-->"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?s)%%.*?%%"#, with: "", options: .regularExpression)
        return out
    }

    /// One line as plain text: embeds dropped, links read as their text, highlight/emphasis markers and escapes removed.
    public static func plain(_ line: String) -> String {
        var text = line
        text = regex(wikiLinkPattern).stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "\u{0}$1\u{1}$2\u{1}$3\u{1}$4\u{0}")
        // Resolve the placeholders: embeds vanish, links read as alias or note name.
        var resolved = ""
        let parts = text.components(separatedBy: "\u{0}")
        for (index, part) in parts.enumerated() {
            guard index % 2 == 1 else { resolved += part; continue }
            let fields = part.components(separatedBy: "\u{1}")
            guard fields.count == 4, fields[0] != "!" else { continue }
            let anchor = fields[2].isEmpty ? nil : String(fields[2].dropFirst())
            resolved += WikiLink(target: fields[1], heading: anchor?.hasPrefix("^") == true ? nil : anchor,
                                 alias: fields[3].isEmpty ? nil : String(fields[3].dropFirst())).display
        }
        text = resolved
        text = replace(#"(?<!\\)!(?<!\\)\[(?:[^\]\n\\]|\\.)*\]\([^)\n]*\)"#, in: text, with: "")
        text = replace(#"(?<!\\)\[((?:[^\]\n\\]|\\.)*)\]\([^)\n]*\)"#, in: text, with: "$1")
        text = replace(#"(?<!\\)==([^=\n]+?)=="#, in: text, with: "$1")
        text = replace(#"^\s*[-*+]\s+\[[ xX/\-]\]\s+"#, in: text, with: "")
        text = replace(#"^\s*(?:[-*+]|\d+[.)])\s+"#, in: text, with: "")
        text = replace(#"(\*\*|__|~~)(.+?)\1"#, in: text, with: "$2")
        text = replace(#"\\([\\`*_\[\]{}()<>#+\-.!|=%$^~&])"#, in: text, with: "$1")
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Untrusted text (a web page) made inert as Markdown: no links, embeds, remote images, code blocks (which some
    /// plugins execute, e.g. `dataviewjs`), HTML, comments, block ids, tags or WorkScribe region markers. Reads the
    /// same; a backslash escape renders as the character.
    public static func escapeUntrusted(_ text: String) -> String {
        let special = Set("\\`*_[]<>#=%$^|~{}!")
        var out = ""
        out.reserveCapacity(text.count + text.count / 16)
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            var escaped = ""
            for character in line where character == "\t" || !(character.unicodeScalars.first.map { CharacterSet.controlCharacters.contains($0) } ?? false) {
                if special.contains(character) { escaped.append("\\") }
                escaped.append(character)
            }
            // A line that starts like a list, quote or heading stays a paragraph line.
            if let first = escaped.first, "-+:".contains(first) || escaped.range(of: #"^\d+[.)]"#, options: .regularExpression) != nil {
                escaped = "\\" + escaped
            }
            out += escaped + "\n"
        }
        return String(out.dropLast())
    }

    /// A string safe inside `[[target|alias]]` or a list line: one line, no link or comment syntax.
    public static func inlineSafe(_ text: String, limit: Int = 200) -> String {
        let cleaned = text.replacingOccurrences(of: #"[\[\]|#^<>`\n\r\t]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(limit))
    }
}
