import Foundation

/// A file or a note attached to a conversation or a meeting. Files are copied next to their owner (so the index ref
/// stays valid when the original moves); files over `Attachments.copyLimit` are bookmarked and read in place. Notes
/// are stored as Markdown files, so the index reads them like any document.
public struct Attachment: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case file, note }
    public var id: String
    public var kind: Kind
    public var name: String
    /// Path relative to the owner's attachments folder (a copy, or the note's Markdown file); nil when bookmarked.
    public var storedFile: String?
    /// Where the file came from.
    public var originalPath: String?
    /// A bookmark (WorkScribe isn't sandboxed) for files too large to copy; follows the file if it moves.
    public var bookmark: Data?
    public var byteCount: Int?
    public var addedAt: Date
    /// "indexed", "pending", or why it couldn't be read ("unsupported type .key").
    public var indexState: String?

    public init(id: String = UUID().uuidString, kind: Kind, name: String, storedFile: String?, originalPath: String? = nil,
                bookmark: Data? = nil, byteCount: Int? = nil, addedAt: Date = Date(), indexState: String? = "pending") {
        self.id = id; self.kind = kind; self.name = name; self.storedFile = storedFile; self.originalPath = originalPath
        self.bookmark = bookmark; self.byteCount = byteCount; self.addedAt = addedAt; self.indexState = indexState
    }
}

/// Who an attachment belongs to. Its index sources carry `indexRoot` as their root, which keeps folder syncs from
/// removing them and lets retrieval find "this conversation's" sources.
public enum AttachmentOwner: Hashable, Sendable {
    case conversation(String)
    case meeting(String)

    public static let rootPrefix = "attachment:"
    public var indexRoot: String {
        switch self {
        case .conversation(let id): Self.rootPrefix + "conversation:" + id
        case .meeting(let id): Self.rootPrefix + "meeting:" + id
        }
    }
    public static func isAttachmentRoot(_ root: String?) -> Bool { root?.hasPrefix(rootPrefix) == true }
}

/// File operations for attachments, kept free of UI so they can be tested.
public struct Attachments: Sendable {
    /// Larger files are bookmarked instead of copied.
    public static let copyLimit = 200 * 1024 * 1024
    public let folder: URL
    public init(folder: URL) { self.folder = folder }

    /// The file the index reads and links open.
    public func url(of attachment: Attachment) -> URL? {
        if let stored = attachment.storedFile { return folder.appendingPathComponent(stored) }
        if let bookmark = attachment.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) { return url }
        }
        return attachment.originalPath.map { URL(fileURLWithPath: $0) }
    }

    public func addFile(_ source: URL) throws -> Attachment {
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let name = source.lastPathComponent
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        if size > Self.copyLimit {
            let bookmark = try? source.bookmarkData(options: [],
                                                    includingResourceValuesForKeys: nil, relativeTo: nil)
            return Attachment(kind: .file, name: name, storedFile: nil, originalPath: source.path, bookmark: bookmark, byteCount: size)
        }
        try ensureFolder()
        let target = uniqueURL(for: name)
        try FileManager.default.copyItem(at: source, to: target)
        return Attachment(kind: .file, name: name, storedFile: target.lastPathComponent, originalPath: source.path, byteCount: size)
    }

    /// Saves pasted or dropped text as `<title>.md`.
    public func addNote(_ text: String, title: String? = nil) throws -> Attachment {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        let name = Self.noteTitle(title, text: body)
        try ensureFolder()
        let target = uniqueURL(for: Self.safeFileName(name) + ".md")
        try ("# \(name)\n\n" + body + "\n").write(to: target, atomically: true, encoding: .utf8)
        return Attachment(kind: .note, name: name, storedFile: target.lastPathComponent, byteCount: body.utf8.count)
    }

    /// Deletes the copy (never the original of a bookmarked file).
    public func remove(_ attachment: Attachment) {
        guard let stored = attachment.storedFile else { return }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(stored))
    }

    /// The note's text, for display.
    public func noteText(_ attachment: Attachment) -> String? {
        guard attachment.kind == .note, let url = url(of: attachment), let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = raw.components(separatedBy: "\n")
        let body = lines.first?.hasPrefix("# ") == true ? lines.dropFirst().joined(separator: "\n") : raw
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func noteTitle(_ title: String?, text: String) -> String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return String(title.prefix(80)) }
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Note"
        let cleaned = first.trimmingCharacters(in: CharacterSet(charactersIn: "#-*> ").union(.whitespaces))
        return cleaned.isEmpty ? "Note" : String(cleaned.prefix(60))
    }

    public static func safeFileName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        let cleaned = name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return cleaned.isEmpty ? "Note" : String(cleaned.prefix(80))
    }

    private func ensureFolder() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// "report.pdf", then "report 2.pdf", …
    func uniqueURL(for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }
}

/// Attachments of a meeting live in `<meeting folder>/attachments/`, listed in `attachments.json` beside the transcript
/// (a sidecar, so `Meeting` itself is unchanged).
public struct MeetingAttachmentStore {
    public let store: MeetingStore
    public init(store: MeetingStore) { self.store = store }
    public func folder(_ meetingID: String) throws -> URL { try store.directory(meetingID).appendingPathComponent("attachments", isDirectory: true) }
    public func files(_ meetingID: String) throws -> Attachments { Attachments(folder: try folder(meetingID)) }
    private func manifest(_ meetingID: String) throws -> URL { try store.directory(meetingID).appendingPathComponent("attachments.json") }
    public func load(_ meetingID: String) -> [Attachment] {
        guard let url = try? manifest(meetingID), let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Attachment].self, from: data)) ?? []
    }
    public func save(_ attachments: [Attachment], for meetingID: String) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(attachments).write(to: try manifest(meetingID), options: .atomic)
    }
}
