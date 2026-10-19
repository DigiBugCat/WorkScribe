import Foundation
import Darwin

/// A vault-owned image. Only its reference travels in document snapshots; derived evidence lives in
/// the ephemeral meeting ledger and is removed with it. The original is never copied into that ledger.
public struct NoteImage: Codable, Equatable, Sendable {
    public var target: String
    public var path: String?
    public var fingerprint: String?
    public var text: String?
    public var caption: String?
    public var method: String?
    public var seconds: Double?
    public init(target: String, path: String? = nil) { self.target = target; self.path = path }
    public var evidence: String { [caption, text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n") }
}

public enum NoteImageContent {
    public static let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tif", "tiff"]
    // Shorthand is read throughout Find; recompiling these ICU patterns per read accumulates large temporaries.
    private static let codePattern = try! NSRegularExpression(pattern: #"(?s)```.*?```|`[^`]*`"#)
    private static let imagePattern = try! NSRegularExpression(pattern: #"!\[\[([^\]\n]+)\]\]|!\[[^\]\n]*\]\(\s*(<[^>\n]+>|(?:[^()\s]|\([^()]*\))+)\s*(?:["'][^\n]*?["']\s*)?\)"#)
    private static let definitionPattern = try! NSRegularExpression(pattern: #"(?m)^ {0,3}\[([^\]\n]+)\]:\s*(<[^>]+>|\S+)"#)
    private static let referencePattern = try! NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\[([^\]\n]*)\]"#)
    public static func parse(_ text: String, source document: String? = nil) -> (shorthand: String, targets: [String]) {
        // Code spans/fences are data, not embeds. Mask them without changing UTF-16 positions.
        let source = text as NSString
        let masked = NSMutableString(string: text)
        for match in codePattern.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            masked.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length))
        }
        let result = NSMutableString(string: text)
        var targets: [String] = []
        for match in imagePattern.matches(in: masked as String, range: NSRange(location: 0, length: masked.length)).reversed() {
            let wiki = match.range(at: 1).location != NSNotFound
            var target = source.substring(with: match.range(at: wiki ? 1 : 2))
            target = wiki ? String(target.split(separator: "|", maxSplits: 1)[0]) : target.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            target = (target.removingPercentEncoding ?? target).components(separatedBy: "#")[0]
            guard !wiki || extensions.union(["svg"]).contains((target as NSString).pathExtension.lowercased()) else { continue }
            targets.insert(target, at: 0)
            result.replaceCharacters(in: match.range, with: "")
        }
        let definitions = document ?? text
        let defs = definitions as NSString
        var refs: [String: String] = [:]
        for hit in definitionPattern.matches(in: definitions, range: NSRange(location:0,length:defs.length)) {
            refs[defs.substring(with:hit.range(at:1)).lowercased()] = defs.substring(with:hit.range(at:2)).trimmingCharacters(in:CharacterSet(charactersIn:"<>"))
        }
        // Resolve after direct-image removal, so offsets still refer to this intermediate string.
        let intermediate = result as String
        for hit in referencePattern.matches(in: intermediate, range:NSRange(location:0,length:result.length)).reversed() {
            let value = result.substring(with:hit.range)
            if text.contains("`" + value + "`") { continue }
            let label = result.substring(with:hit.range(at:2))
            let key = (label.isEmpty ? result.substring(with:hit.range(at:1)) : label).lowercased()
            targets.insert(refs[key] ?? "reference:" + key, at:0)
            result.replaceCharacters(in:hit.range,with:"")
        }
        let shorthand = NotePlainText.clean(result as String)
        return (shorthand, targets)
    }
    /// No network, absolute paths outside the selected vault, hidden metadata, or symlink escapes.
    /// Foundation deliberately aliases /private/var back to /var on macOS. Use POSIX identity
    /// so enumeration, FSEvents, deletion, and symlink boundary checks share the same path.
    public static func canonicalURL(_ url: URL) -> URL {
        if let path = realpath(url.path, nil) {
            defer { free(path) }
            return URL(fileURLWithPath:String(cString:path))
        }
        if let path = realpath(url.deletingLastPathComponent().path,nil) {
            defer { free(path) }
            return URL(fileURLWithPath:String(cString:path)).appendingPathComponent(url.lastPathComponent)
        }
        return FileIdentity.url(url)
    }
    public static func isMaterialized(_ url: URL) -> Bool {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return false }
        return info.st_flags & UInt32(SF_DATALESS) == 0
    }
    public static func resolve(_ image: NoteImage, note: URL, vault: URL) -> URL? {
        guard !image.target.contains(":"), !image.target.hasPrefix("//") else { return nil }
        let root = canonicalURL(vault)
        let candidates = image.path.map { [URL(fileURLWithPath: $0)] } ?? [note.deletingLastPathComponent().appendingPathComponent(image.target), vault.appendingPathComponent(image.target)]
        return candidates.first { url in
            let resolved = canonicalURL(url)
            let relative = String(resolved.path.dropFirst(root.path.count + 1))
            return resolved.path.hasPrefix(root.path + "/") && !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") })
                && extensions.contains(resolved.pathExtension.lowercased()) && FileManager.default.fileExists(atPath: resolved.path)
        }.map(canonicalURL)
    }
}

/// Matching/prompt view only. The user's Markdown and document offsets remain untouched.
public enum NotePlainText {
    private static let rules: [(NSRegularExpression, String)] = [
        (#"(?m)^\s*(?:(?:>\s*)+|#{1,6}\s+)?(?:[-*+]\s+|\d+[.)]\s+)?(?:\[[ xX-]\]\s*)?"#, ""),
        (#"\[\[([^\]|]+)\|([^\]]+)\]\]"#, "$2"),
        (#"\[\[([^\]]+)\]\]"#, "$1"),
        (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
        (#"<!--.*?-->|<[^>]+>"#, ""),
        (#"(\*\*|__|~~|`)(.+?)\1"#, "$2"),
        (#"(?<!\w)([*_])(.+?)\1(?!\w)"#, "$2"),
        (#"\s+\^[\w-]+\s*$"#, "")
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
    public static func clean(_ text: String) -> String {
        var value = text
        for (pattern, replacement) in rules {
            value = pattern.stringByReplacingMatches(in: value, range: NSRange(location: 0, length: (value as NSString).length), withTemplate: replacement)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Note {
    public var shorthand: String { NoteImageContent.parse(text).shorthand }
    public var isImage: Bool { !(images ?? []).isEmpty && shorthand.isEmpty }
    public var imageEvidence: String { (images ?? []).map(\.evidence).filter { !$0.isEmpty }.joined(separator: "\n") }
    public var matchingText: String { [shorthand, imageEvidence].filter { !$0.isEmpty }.joined(separator: "\n") }
}
