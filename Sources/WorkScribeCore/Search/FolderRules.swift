// Ported from DigUp (MIT, © 2026 Abdur Rahim), Sources/DigUpKit/Rules.swift and Sources/DigUpKit/Extractors.swift
// (`DocExtractor.chunks`, `plainText(fromHTML:)`) @ f9b8106. See Resources/licenses/digup.
// Changes: WorkScribe's kinds (no code index, no screenshot/photo split), extension lists trimmed to what we extract.
import Foundation

/// What gets indexed in a folder the user adds.
public enum FolderRules {
    static let skippedFolderNames: Set<String> = [
        "node_modules", "bower_components", "venv", "site-packages", "__pycache__", "DerivedData", "Pods", "Carthage",
    ]
    public static let documentExtensions: Set<String> = ["txt", "text", "md", "markdown", "rtf", "docx", "doc", "odt", "html", "htm", "pdf"]
    public static let audioExtensions: Set<String> = ["wav", "m4a", "mp3", "aac", "aif", "aiff", "caf", "flac", "ogg", "opus"]
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "webp"]

    /// Keys, certificates, password and credential files: never read, wherever they are.
    public static func isSecret(_ name: String) -> Bool {
        let lower = name.lowercased()
        let secretTypes: Set<String> = ["pem", "key", "p12", "pfx", "keystore", "jks", "ppk", "kdbx", "gpg", "asc",
                                        "crt", "cer", "der", "p8", "mobileprovision"]
        if secretTypes.contains((lower as NSString).pathExtension) { return true }
        return ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", ".env", "secret", "credential", ".netrc", ".npmrc",
                ".pypirc", "htpasswd", ".htpasswd"].contains(where: lower.hasPrefix)
    }

    public static func kind(of url: URL) -> ChunkKind? {
        let name = url.lastPathComponent
        guard !name.hasPrefix("."), !isSecret(name) else { return nil }
        let ext = url.pathExtension.lowercased()
        if documentExtensions.contains(ext) { return .document }
        if audioExtensions.contains(ext) { return .audio }
        if videoExtensions.contains(ext) { return .video }
        if imageExtensions.contains(ext) { return .image }
        return nil
    }

    /// Why a folder isn't walked, or nil.
    public static func skipReason(forFolder url: URL) -> String? {
        let name = url.lastPathComponent
        if name.hasPrefix(".") { return "hidden folder" }
        if skippedFolderNames.contains(name) { return "developer folder" }
        if name.hasSuffix(".noindex") { return ".noindex folder" }
        if url.path == FileManager.default.homeDirectoryForCurrentUser.path + "/Library" { return "~/Library" }
        return nil
    }

    /// Indexable files under `root`, with their kinds.
    public static func walk(_ root: URL) -> [(url: URL, kind: ChunkKind)] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isPackageKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [(URL, ChunkKind)] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if skipReason(forFolder: url) != nil { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true, let kind = kind(of: url) else { continue }
            out.append((url.standardizedFileURL, kind))
        }
        return out.sorted { $0.0.path < $1.0.path }
    }
}

public enum TextExtraction {
    /// Good enough for search: drops scripts, styles and comments, turns block ends into line breaks, strips tags.
    public static func plainText(fromHTML html: String) -> String {
        var text = html
        for pattern in [#"(?is)<script\b.*?</script\s*>"#, #"(?is)<style\b.*?</style\s*>"#, #"(?s)<!--.*?-->"#,
                        #"(?is)<head\b.*?</head\s*>"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"(?i)<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article)\b[^>]*>"#,
                                         with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
                        "&apos;": "'", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…"]
        for (entity, character) in entities { text = text.replacingOccurrences(of: entity, with: character) }
        return text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\n\s*"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// RMS of a window; at or below 0.003 (≈ −50 dBFS) DigUp treats it as silence that isn't worth a vector.
    public static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
    public static let silenceRMS: Float = 0.003
}
