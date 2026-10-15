import Foundation

/// Where WorkScribe keeps notes. Persisted by the app; `path == nil` means WorkScribe's own notes folder.
public struct VaultSettings: Codable, Equatable, Sendable {
    /// An Obsidian vault or any folder the user picked.
    public var path: String?
    /// Write meeting write-ups (and people pages) when a meeting is finalized.
    public var writeMeetings: Bool
    /// Index the folder's Markdown as a search source.
    public var indexVault: Bool
    public init(path: String? = nil, writeMeetings: Bool = true, indexVault: Bool = true) {
        self.path = path.map(FileIdentity.path); self.writeMeetings = writeMeetings; self.indexVault = indexVault
    }

    /// WorkScribe's notes folder when no vault is chosen: clips still need a home.
    public static var localFolder: URL {
        if let dir = ProcessInfo.processInfo.environment["WORKSCRIBE_NOTES_DIR"] { return URL(fileURLWithPath: dir) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WorkScribe/Notes")
    }
    public var root: URL { FileIdentity.url(path.map { URL(fileURLWithPath: $0) } ?? Self.localFolder) }
}

/// A saved clip, as the app reports it to the UI.
public struct SavedClip: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// Vault-relative path including `.md`.
    public var path: String
    public var title: String
    public var url: String
    public var site: String?
    public var meetingID: String?
    public var offset: Double?
    public var clippedAt: Date
    public var link: ClipLink { ClipLink(path: String(path.dropLast(3)), title: title, site: site, offset: offset) }
}

/// Writes WorkScribe's Markdown into a vault (or any folder) by direct file writes, which Obsidian picks up on its own.
///
/// - Every write is atomic: a temporary file in the same folder, then `rename`. A new note never replaces a file that
///   appeared meanwhile (`RENAME_EXCL`).
/// - Before replacing a note, the file is re-read and must still hash to what the merge started from; otherwise the
///   merge is redone once against the newer text.
/// - Meeting notes are merged region by region (`VaultWriter.merge`); user edits are never overwritten, and a
///   conflicting new version goes to a sibling `… .conflict.md`.
/// - People pages are created once and never modified. `Inbox.md` is append-only.
/// - `.obsidian/` is never read or written. Writes are serialized within the process.
public final class VaultStore: @unchecked Sendable {
    public let root: URL
    public var timeZone: TimeZone
    let stateURL: URL
    private let legacyStateURL: URL
    private let lock = NSLock()

    public enum Outcome: Equatable, Sendable {
        case created(String), updated(String), unchanged(String)
        /// The note got the updates it could take; the full new version is at `conflict`.
        case conflicted(String, conflict: String, sections: [String])
        /// The note is an iCloud placeholder or unreadable right now; nothing was written.
        case unavailable(String)
        public var path: String {
            switch self {
            case .created(let p), .updated(let p), .unchanged(let p), .unavailable(let p), .conflicted(let p, _, _): p
            }
        }
    }

    public enum Failure: Error, Equatable { case changedDuringWrite, notAVaultPath(String) }

    /// `stateDirectory` holds WorkScribe's bookkeeping (meeting → note path, clips per meeting), outside the vault.
    public init(root: URL, stateDirectory: URL, timeZone: TimeZone = .current) {
        self.root = FileIdentity.url(root); self.timeZone = timeZone
        let key = VaultWriter.hash(self.root.path)
        stateURL = stateDirectory.appendingPathComponent("vault-\(key).json")
        legacyStateURL = stateDirectory.appendingPathComponent("vault-\(VaultWriter.hash(root.standardizedFileURL.path)).json")
    }

    /// The folder's name, which is what Obsidian calls the vault.
    public var name: String { root.lastPathComponent }
    /// Whether Obsidian has opened this folder as a vault.
    public var isObsidianVault: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(".obsidian").path) }

    /// `obsidian://open?vault=…&file=…` for a vault-relative path, each value percent-encoded; nil outside Obsidian vaults.
    public func obsidianURL(_ relativePath: String) -> URL? {
        isObsidianVault ? VaultLinks.obsidian(vault: name, file: relativePath) : nil
    }

    // MARK: Bookkeeping

    struct State: Codable {
        var meetings: [String: String] = [:]
        var clips: [String: [SavedClip]] = [:]
        var inbox: [SavedClip] = []
        /// meeting id → note id → block id (`e1`…), so block links stay put.
        var blocks: [String: [String: String]] = [:]
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            meetings = try c.decodeIfPresent([String: String].self, forKey: .meetings) ?? [:]
            clips = try c.decodeIfPresent([String: [SavedClip]].self, forKey: .clips) ?? [:]
            inbox = try c.decodeIfPresent([SavedClip].self, forKey: .inbox) ?? []
            blocks = try c.decodeIfPresent([String: [String: String]].self, forKey: .blocks) ?? [:]
        }
    }

    func loadState() -> State {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return ((try? Data(contentsOf: stateURL)) ?? (try? Data(contentsOf: legacyStateURL))).flatMap { try? decoder.decode(State.self, from: $0) } ?? State()
    }

    func saveState(_ state: State) throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    /// Clips received for a meeting, oldest first.
    public func clips(forMeeting id: String) -> [SavedClip] {
        lock.lock(); defer { lock.unlock() }
        return loadState().clips[id] ?? []
    }

    public func inboxClips() -> [SavedClip] {
        lock.lock(); defer { lock.unlock() }
        return loadState().inbox
    }

    /// The vault-relative path of a meeting's note, if WorkScribe wrote one (follows renames by `workscribe_id`).
    public func notePath(forMeeting id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return locate(meetingID: id, state: loadState())
    }

    public func blockIDs(forMeeting id: String) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return loadState().blocks[id] ?? [:]
    }

    func locate(meetingID: String, state: State) -> String? {
        if let known = state.meetings[meetingID], workscribeID(at: known) == meetingID { return known }
        // Renamed or moved in Obsidian: find it by its id.
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "md", !url.lastPathComponent.hasSuffix(".conflict.md") else { continue }
            let relative = relativePath(url)
            if workscribeID(at: relative) == meetingID { return relative }
        }
        return nil
    }

    func workscribeID(at relative: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: url(relative).path) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
        guard head.hasPrefix("---") else { return nil }
        return Markdown.match(#"(?m)^(?:workscribe_id|workscribe):\s*"?([^"\n]+?)"?\s*$"#, head)?[1]
    }

    public func url(_ relative: String) -> URL { FileIdentity.url(root.appendingPathComponent(relative)) }

    func relativePath(_ url: URL) -> String {
        let full = FileIdentity.url(url).path, base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return full.hasPrefix(base) ? String(full.dropFirst(base.count)) : url.lastPathComponent
    }

    // MARK: Meetings

    /// Builds the write-up for `meeting` with its remembered block ids and clips, and writes it.
    @discardableResult
    public func writeMeeting(_ meeting: Meeting, brief: String? = nil, actions: [ActionItem] = [], customer: String? = nil) throws -> Outcome {
        if meeting.document != nil {
            return .unchanged(try finalizeDocument(meeting).replacingOccurrences(of: root.path + "/", with: ""))
        }
        let state: State = { lock.lock(); defer { lock.unlock() }; return loadState() }()
        let writeUp = MeetingWriteUp(meeting, brief: brief, actions: actions, customer: customer,
                                     clips: (state.clips[meeting.id] ?? []).map(\.link), blockIDs: state.blocks[meeting.id] ?? [:])
        return try writeMeeting(writeUp)
    }

    /// Whether WorkScribe has written (and still tracks) a note for this meeting.
    public func hasNote(forMeeting id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return loadState().meetings[id] != nil
    }

    /// Creates or updates a meeting's note at `Meetings/<date> <title>.md` and the people pages it links.
    @discardableResult
    public func writeMeeting(_ writeUp: MeetingWriteUp) throws -> Outcome {
        lock.lock(); defer { lock.unlock() }
        var state = loadState()
        var writeUp = writeUp
        if writeUp.clips.isEmpty { writeUp.clips = (state.clips[writeUp.meetingID] ?? []).map(\.link) }
        for note in writeUp.notes { state.blocks[writeUp.meetingID, default: [:]][note.id] = note.blockID }
        for name in writeUp.attendees + writeUp.actions.compactMap(\.owner) { try ensurePersonLocked(name) }

        let outcome: Outcome
        if let existing = locate(meetingID: writeUp.meetingID, state: state) {
            outcome = try update(existing, with: writeUp)
            state.meetings[writeUp.meetingID] = existing
        } else {
            let day = VaultWriter.dayString(writeUp.startedAt, timeZone: timeZone)
            let relative = try createUnique(folder: "Meetings", base: "\(day) \(VaultPaths.fileName(writeUp.title))",
                                            text: VaultWriter.render(writeUp, timeZone: timeZone))
            state.meetings[writeUp.meetingID] = relative
            outcome = .created(relative)
        }
        try saveState(state)
        return outcome
    }

    func update(_ relative: String, with writeUp: MeetingWriteUp) throws -> Outcome {
        let target = url(relative)
        for attempt in 0..<2 {
            guard let data = try? Data(contentsOf: target) else { return .unavailable(relative) }
            let existing = String(decoding: data, as: UTF8.self)
            let merge = VaultWriter.merge(existing: existing, update: writeUp, timeZone: timeZone)
            do {
                if merge.changed { try replace(target, with: merge.text, expected: VaultWriter.sha256(data)) }
            } catch Failure.changedDuringWrite where attempt == 0 { continue }
            guard !merge.conflicts.isEmpty else { return merge.changed ? .updated(relative) : .unchanged(relative) }
            let conflict = String(relative.dropLast(3)) + ".conflict.md"
            try replace(url(conflict), with: conflictNote(writeUp, original: relative, sections: merge.conflicts), expected: nil)
            return .conflicted(relative, conflict: conflict, sections: merge.conflicts)
        }
        throw Failure.changedDuringWrite
    }

    func conflictNote(_ writeUp: MeetingWriteUp, original: String, sections: [String]) -> String {
        let fresh = VaultWriter.render(writeUp, timeZone: timeZone)
        let (yaml, body) = Frontmatter.split(fresh)
        var front = Frontmatter.parse(yaml ?? "")
        front["type"] = .string("workscribe-conflict")
        front["workscribe_id"] = nil
        front["tags"] = nil
        let link = Markdown.inlineSafe(String(original.dropLast(3)), limit: 400)
        return "---\n\(front.render())\n---\n> [!warning] WorkScribe has a newer version of \(sections.joined(separator: ", "))\n"
            + "> You edited [[\(link)]], so WorkScribe left it alone. Copy what you want from here, then delete this note.\n\n"
            + Markdown.removingComments(body).trimmingCharacters(in: .newlines) + "\n"
    }

    /// Creates the editor-owned note once. Later calls follow renames by frontmatter identity.
    public func openDocument(_ meeting: Meeting) throws -> NoteDocument {
        lock.lock(); defer { lock.unlock() }
        var state = loadState()
        if let document = meeting.document {
            guard let path = locate(meetingID: meeting.id, state: state) else { throw NoteDocument.Failure.missing }
            var current = document; current.path = url(path).path
            return current
        }
        let day = VaultWriter.dayString(meeting.startedAt, timeZone: timeZone)
        var front = Frontmatter()
        let stamp = DateFormatter(); stamp.timeZone = timeZone; stamp.dateFormat = "yyyy-MM-dd HH:mm"
        front["date"] = .string(stamp.string(from: meeting.startedAt))
        if let ended = meeting.endedAt { front["duration"] = .string("\(max(1, Int(ended.timeIntervalSince(meeting.startedAt) / 60))) min") }
        if let attendees = meeting.attendees, !attendees.isEmpty { front["attendees"] = .list(attendees.map { "[[" + $0 + "]]" }) }
        front["tags"] = .list(["meeting"])
        front["workscribe"] = .string(meeting.id)
        var source = "---\n" + front.render() + "\n---\n\n"
        var blocks: [NoteDocument.Block] = []
        for note in meeting.notes ?? [] {
            let from = (source as NSString).length
            source += note.text
            blocks.append(.init(id: note.id, from: from, to: (source as NSString).length, text: note.text, at: note.createdAt, section: note.section))
            source += "\n"
        }
        if blocks.isEmpty { source += "- " }
        let path: String
        if let existing = locate(meetingID: meeting.id, state: state) { path = existing }
        else { path = try createUnique(folder: "Meetings", base: day + " " + VaultPaths.fileName(meeting.title), text: source) }
        state.meetings[meeting.id] = path; try saveState(state)
        let disk = try String(contentsOf: url(path), encoding: .utf8)
        return NoteDocument(path: url(path).path, source: disk, blocks: disk == source ? blocks : [])
    }

    public func validateDocumentPath(_ document: NoteDocument, meetingID: String) throws {
        let target = FileIdentity.url(URL(fileURLWithPath: document.path))
        let base = root.path + "/"
        guard target.path.hasPrefix(base), !target.path.contains("/.obsidian/"),
              workscribeID(at: String(target.path.dropFirst(base.count))) == meetingID else { throw NoteDocument.Failure.missing }
    }

    /// Compare-and-swap the exact source. A racing external edit is never overwritten or copied aside.
    public func finalizeDocument(_ meeting: Meeting, allowRebase: Bool = false) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard let document = meeting.document,
              let relative = locate(meetingID: meeting.id, state: loadState()) else { throw NoteDocument.Failure.missing }
        if document.finalized == true { return FileManager.default.fileExists(atPath:document.path) ? document.path : url(relative).path }
        let target = url(relative)
        guard let data = try? Data(contentsOf: target) else { throw NoteDocument.Failure.missing }
        var text = try document.finalizedText(meeting: meeting)
        // A crash after the atomic rename but before the retention journal must be replayable.
        if String(data: data, encoding: .utf8) == text { return target.path }
        if String(data: data, encoding: .utf8) != document.source {
            guard allowRebase, let current = String(data: data, encoding: .utf8) else {
                let conflict = target.deletingPathExtension().path + " (WorkScribe).md"
                let conflictURL = URL(fileURLWithPath: conflict)
                guard !FileManager.default.fileExists(atPath: conflict) else { throw NoteDocument.Failure.changed }
                try text.write(to: conflictURL, atomically: true, encoding: .utf8)
                return conflict
            }
            text = try document.rebased(on: current).finalizedText(meeting: meeting)
        }
        try replace(target, with: text, expected: VaultWriter.sha256(data))
        return target.path
    }

    // MARK: People

    /// `People/<Name>.md`, created if missing and never modified. Returns the vault-relative path.
    @discardableResult
    public func ensurePerson(_ name: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        return try ensurePersonLocked(name)
    }

    @discardableResult
    func ensurePersonLocked(_ name: String) throws -> String {
        let file = VaultPaths.fileName(name)
        let relative = "People/\(file).md"
        guard !exists(relative) else { return relative }
        var front = Frontmatter()
        front["type"] = .string("person")
        front["tags"] = .list(["person"])
        let text = "---\n\(front.render())\n---\n# \(file)\n\nMeetings with \(file) link here; see backlinks.\n"
        do { try create(url(relative), text: text) } catch CocoaError.fileWriteFileExists {}
        return relative
    }

    // MARK: Clips

    /// Saves a page clip as `Clippings/<date> <title>.md` (frontmatter Web Clipper's template also uses), attached to a
    /// meeting (with the time into it) or listed in `Inbox.md`. The page's text is escaped so it can't become links,
    /// embeds, code blocks or comments in the vault.
    public func saveClip(_ page: PageCapture, meeting: (id: String, title: String)?, offset: Double?, at date: Date = Date()) throws -> SavedClip {
        lock.lock(); defer { lock.unlock() }
        let id = UUID().uuidString
        let title = Markdown.inlineSafe(page.title.isEmpty ? page.url : page.title, limit: 200)
        let site = page.site.map { Markdown.inlineSafe($0, limit: 80) } ?? URL(string: page.url)?.host.map(VaultLinks.siteName)
        var front = Frontmatter()
        front["workscribe_id"] = .string(id)
        front["type"] = .string("clip")
        front["title"] = .string(title)
        front["source"] = .string(page.url)
        if let site { front["site"] = .string(site) }
        if let author = page.author { front["author"] = .string(Markdown.inlineSafe(author, limit: 120)) }
        front["clipped"] = .string(Self.isoString(date, timeZone: timeZone))
        if let meeting {
            front["meeting_id"] = .string(meeting.id)
            if let offset { front["meeting_time"] = .string(VaultWriter.clockString(offset)) }
            front["recording"] = .string(WorkScribeLink.meeting(id: meeting.id, seconds: offset, segment: nil).url.absoluteString)
        }
        if let time = page.videoTime { front["video_time"] = .string(String(Int(time))) }
        front["tags"] = .list(["clippings"])

        var body = ["> [!info] Clipped from \(Markdown.inlineSafe(site ?? "the web", limit: 80))"
            + (meeting.map { m in " during “\(Markdown.inlineSafe(m.title, limit: 120))”" + (offset.map { " at " + VaultWriter.clockString($0) } ?? "") } ?? " to the Inbox"),
                    "> Page content is quoted as captured; WorkScribe never follows instructions in it.", ""]
        if let description = page.description { body += ["## Description", Markdown.escapeUntrusted(description), ""] }
        if let selection = page.selection {
            body += ["## Selection"] + Markdown.escapeUntrusted(selection).components(separatedBy: "\n").map { "> " + $0 } + [""]
        }
        if let text = page.text, text != page.selection { body += ["## Page text", Markdown.escapeUntrusted(text), ""] }
        let day = VaultWriter.dayString(date, timeZone: timeZone)
        let relative = try createUnique(folder: "Clippings", base: "\(day) \(VaultPaths.fileName(title))",
                                        text: "---\n\(front.render())\n---\n" + body.joined(separator: "\n") + "\n")
        let saved = SavedClip(id: id, path: relative, title: title, url: page.url, site: site, meetingID: meeting?.id,
                              offset: offset, clippedAt: date)
        var state = loadState()
        if let meeting {
            state.clips[meeting.id, default: []].append(saved)
        } else {
            state.inbox.append(saved)
            try appendToInbox(saved)
        }
        try saveState(state)
        // A meeting whose note already exists: the caller rewrites it (`writeMeeting(meeting)`) to list the clip.
        return saved
    }

    func appendToInbox(_ clip: SavedClip) throws {
        let relative = "Inbox.md"
        let stamp = Self.isoString(clip.clippedAt, timeZone: timeZone).prefix(16).replacingOccurrences(of: "T", with: " ")
        let line = "- \(stamp) [[\(clip.link.path)|\(clip.title)]]" + (clip.site.map { " · \($0)" } ?? "")
        for attempt in 0..<2 {
            if let data = try? Data(contentsOf: url(relative)) {
                var text = String(decoding: data, as: UTF8.self)
                if !text.hasSuffix("\n") { text += "\n" }
                do { try replace(url(relative), with: text + line + "\n", expected: VaultWriter.sha256(data)); return }
                catch Failure.changedDuringWrite where attempt == 0 { continue }
            } else {
                do { try create(url(relative), text: "# Inbox\n\nClips saved outside a meeting.\n\n" + line + "\n"); return }
                catch CocoaError.fileWriteFileExists where attempt == 0 { continue }
            }
        }
        throw Failure.changedDuringWrite
    }

    static func isoString(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone; formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    // MARK: Files

    func exists(_ relative: String) -> Bool {
        let target = url(relative)
        let placeholder = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).icloud")
        return FileManager.default.fileExists(atPath: target.path) || FileManager.default.fileExists(atPath: placeholder.path)
    }

    /// Creates `folder/base.md`, or `base (2).md`… when taken. Returns the vault-relative path.
    func createUnique(folder: String, base: String, text: String) throws -> String {
        for number in 1...500 {
            let relative = "\(folder)/\(base)\(number == 1 ? "" : " (\(number))").md"
            if exists(relative) { continue }
            do { try create(url(relative), text: text); return relative }
            catch CocoaError.fileWriteFileExists { continue }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    func guardInside(_ target: URL) throws {
        let path = FileIdentity.url(target).path
        guard path.hasPrefix(root.path + "/"), !path.contains("/.obsidian/") else { throw Failure.notAVaultPath(path) }
    }

    /// Writes a new file atomically; fails with `fileWriteFileExists` rather than replacing one.
    func create(_ target: URL, text: String) throws {
        try guardInside(target)
        let temp = try temporary(beside: target, text: text)
        if renamex_np(temp.path, target.path, UInt32(RENAME_EXCL)) != 0 {
            let code = errno
            unlink(temp.path)
            if code == EEXIST { throw CocoaError(.fileWriteFileExists) }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// Replaces a file atomically. With `expected`, the file must still have that SHA-256 (nobody wrote meanwhile).
    func replace(_ target: URL, with text: String, expected: String?) throws {
        try guardInside(target)
        if let expected {
            guard let current = try? Data(contentsOf: target), VaultWriter.sha256(current) == expected else {
                throw Failure.changedDuringWrite
            }
        }
        let temp = try temporary(beside: target, text: text)
        if rename(temp.path, target.path) != 0 {
            let code = errno; unlink(temp.path)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    func temporary(beside target: URL, text: String) throws -> URL {
        let folder = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appendingPathComponent(".\(target.lastPathComponent).workscribe-\(UUID().uuidString.prefix(8)).tmp")
        try Data(text.utf8).write(to: temp)
        return temp
    }
}

public enum VaultLinks {
    /// `obsidian://open?vault=NAME&file=PATH`, both percent-encoded (spaces as %20, `&`, `=`, `+`, `#` escaped).
    public static func obsidian(vault: String, file: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#/ ")
        guard let v = vault.addingPercentEncoding(withAllowedCharacters: allowed),
              let f = (file.hasSuffix(".md") ? String(file.dropLast(3)) : file).addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "obsidian://open?vault=\(v)&file=\(f)")
    }

    /// `www.example.com` → `example.com`.
    public static func siteName(_ host: String) -> String {
        host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host.lowercased()
    }
}
