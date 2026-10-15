// Ported from DigUp (MIT, © 2026 Abdur Rahim), Sources/DigUpKit/SearchText.swift and the query helpers of
// Sources/DigUpKit/Searcher.swift (`terms`, `patterns`, `isLookup`, `stopwords`) @ f9b8106. See Resources/licenses/digup.
// Changes: English-only kind words for WorkScribe's kinds, meeting words added to the stopwords.
import Foundation

/// Text the way keyword search keeps it and matches it, so that a word is found however it was typed or extracted.
public enum SearchText {
    /// The FTS5 tokenizer DigUp tuned: Porter stemming, accents folded, letters, numbers, private-use and marks.
    public static let tokenizer = "porter unicode61 remove_diacritics 2 categories 'L* N* Co M*'"

    /// NFKC, invisible formatting characters dropped, and Arabic the way people type it.
    public static func normalized(_ text: String) -> String {
        let compatible = text.precomposedStringWithCompatibilityMapping
        var scalars = String.UnicodeScalarView()
        for scalar in compatible.unicodeScalars {
            switch scalar.value {
            case 0x200B: scalars.append(" ")
            case 0x00AD, 0x061C, 0x200C...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0xFEFF: continue
            case 0x0640, 0x064B...0x065F, 0x0670: continue
            case 0x0622, 0x0623, 0x0625, 0x0671: scalars.append("\u{0627}")
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// Scripts that attach endings to words (Indic, Arabic): matched as prefixes.
    public static func inflects(_ word: String) -> Bool {
        word.unicodeScalars.contains { (0x0900...0x0DFF).contains($0.value) || (0x0600...0x06FF).contains($0.value) }
    }

    /// Whether text says something in words: at least a fifth of what isn't space is letters. A table of numbers
    /// gets keyword search only; a meaning vector of digits matches nothing anyone would describe.
    public static func hasWords(_ text: String) -> Bool {
        var letters = 0, others = 0
        for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            if CharacterSet.letters.contains(scalar) { letters += 1 } else { others += 1 }
        }
        return letters > 0 && letters * 4 >= others
    }

    static let stopwords: Set<String> = [
        "a", "an", "the", "of", "in", "on", "at", "to", "for", "with", "and", "or", "my", "me", "that", "this",
        "these", "those", "from", "about", "where", "what", "which", "who", "when", "is", "was", "are", "were", "be",
        "it", "its", "some", "any", "find", "show", "file", "files", "photo", "photos", "picture", "image", "images",
        "screenshot", "screenshots", "video", "videos", "pdf", "document", "documents", "recording",
        "did", "do", "does", "we", "us", "our", "said", "say", "talk", "talked", "meeting", "meetings", "call",
    ]

    /// The content words of a query, normalized as keyword search keeps its text. Kind words and stopwords are
    /// dropped: they describe what to look for, not what's in it.
    public static func terms(_ text: String) -> [String] {
        var seen = Set<String>()
        return normalized(text).lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.unicodeScalars.count >= 2 && !stopwords.contains($0) && seen.insert($0).inserted }
    }

    /// FTS5 patterns for the query's words: quoted, prefixes for the last word while typing and for inflecting scripts.
    public static func patterns(_ terms: [String], prefixLast: Bool = false) -> [String] {
        terms.enumerated().map { index, term in
            let prefix = (prefixLast && index == terms.count - 1) || inflects(term)
            return "\"\(term)\"" + (prefix ? "*" : "")
        }
    }

    /// Codes, IDs and long numbers mean nothing to an embedding but everything to keyword search: a query made of
    /// them weighs words double and meaning half.
    public static func isLookup(_ terms: [String]) -> Bool {
        !terms.isEmpty && terms.allSatisfy {
            $0.contains(where: \.isNumber) && ($0.contains(where: \.isLetter) || $0.count >= 4)
        }
    }

    static let kindWords: [String: ChunkKind] = [
        "meeting": .meetingSegment, "meetings": .meetingSegment, "call": .meetingSegment, "calls": .meetingSegment,
        "pdf": .document, "pdfs": .document, "document": .document, "documents": .document, "doc": .document,
        "docs": .document, "note": .document, "notes": .document, "video": .video, "videos": .video, "clip": .clip, "clips": .clip,
        "clipping": .clip, "clippings": .clip, "article": .clip, "articles": .clip, "webpage": .clip,
        "audio": .audio, "podcast": .audio, "voice": .audio, "song": .audio, "image": .image, "images": .image,
        "photo": .image, "photos": .image, "screenshot": .image, "screenshots": .image, "picture": .image,
        "slide": .screen, "slides": .screen, "screen": .screen, "deck": .screen, "presentation": .screen,
    ]

    /// Kinds the query asks for ("…in a video"): a soft boost, not a filter.
    public static func kindHints(_ text: String) -> Set<ChunkKind> {
        Set(normalized(text).lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .compactMap { kindWords[$0] })
    }

    /// One line from `text` around the first of `terms` it has, the terms marked « ». Nil when none is in it.
    public static func snippet(_ text: String, terms: [String], words: Int = 14) -> String? {
        let tokens = text.split(whereSeparator: \.isWhitespace)
        let folded = tokens.map { normalized(String($0)).lowercased().folding(options: .diacriticInsensitive, locale: nil) }
        func hit(_ token: String) -> Bool {
            let bare = token.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            return terms.contains { bare == $0 || (bare.hasPrefix($0) && bare.count - $0.count <= 3) }
        }
        guard let first = folded.firstIndex(where: hit) else { return nil }
        let start = max(0, first - words / 3), end = min(tokens.count, start + words)
        let body = (start..<end).map { hit(folded[$0]) ? "«\(tokens[$0])»" : String(tokens[$0]) }.joined(separator: " ")
        return (start > 0 ? "…" : "") + body + (end < tokens.count ? "…" : "")
    }

    /// One line, at most `limit` characters: for result lists.
    public static func excerpt(_ text: String, limit: Int = 240) -> String {
        let start = text.prefix(limit * 8)
        let line = String(start).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return line.count > limit || start.endIndex < text.endIndex ? String(line.prefix(limit)) + "…" : line
    }
}
