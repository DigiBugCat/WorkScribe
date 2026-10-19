import CommonCrypto
import Foundation

/// An action item for the write-up's Tasks list.
public struct ActionItem: Equatable, Sendable, Codable {
    public var owner: String?
    public var text: String
    /// `yyyy-MM-dd`.
    public var due: String?
    public var done: Bool
    public init(owner: String? = nil, text: String, due: String? = nil, done: Bool = false) {
        self.owner = owner; self.text = text; self.due = due; self.done = done
    }
}

/// A clip or attachment listed in a meeting write-up.
public struct ClipLink: Equatable, Sendable, Codable {
    /// Vault-relative path without `.md` (`Clippings/2026-10-13 Pricing page`).
    public var path: String
    public var title: String
    public var site: String?
    /// Seconds into the meeting.
    public var offset: Double?
    public init(path: String, title: String, site: String? = nil, offset: Double? = nil) {
        self.path = path; self.title = title; self.site = site; self.offset = offset
    }
}

/// What WorkScribe writes about one meeting. Built from a `Meeting` plus what isn't stored on it yet (brief, action
/// items, customer), which callers supply when they have it.
public struct MeetingWriteUp: Equatable, Sendable {
    public struct NoteLine: Equatable, Sendable {
        public var id: String
        public var markdown: String
        /// `e1`, `e2`…: assigned once per note and kept (`VaultStore` remembers them), so `[[note#^e1]]` links survive
        /// notes being added or removed.
        public var blockID: String
        /// Where in the recording the note came from, as `[mm:ss](workscribe://meeting/…?t=…&segment=…)`.
        public var sources: [Excerpt]
        public init(id: String, markdown: String, blockID: String, sources: [Excerpt] = []) {
            self.id = id; self.markdown = markdown; self.blockID = blockID; self.sources = sources
        }
    }
    /// A moment in the recording that a note or missed topic was written from.
    public struct Excerpt: Equatable, Sendable {
        public var seconds: Double
        public var segment: String?
        public init(seconds: Double, segment: String?) { self.seconds = seconds; self.segment = segment }
    }
    public struct Topic: Equatable, Sendable {
        public var topic: String
        public var text: String
        public var sources: [Excerpt]
        public init(topic: String, text: String, sources: [Excerpt] = []) { self.topic = topic; self.text = text; self.sources = sources }
    }
    public var finalized = false
    public var meetingID: String
    public var title: String
    public var startedAt: Date
    public var duration: TimeInterval?
    public var attendees: [String]
    public var customer: String?
    public var brief: String?
    public var notes: [NoteLine]
    public var missed: [Topic]
    public var actions: [ActionItem]
    public var clips: [ClipLink]

    public init(meetingID: String, title: String, startedAt: Date, duration: TimeInterval? = nil, attendees: [String] = [],
                customer: String? = nil, brief: String? = nil, notes: [NoteLine] = [], missed: [Topic] = [],
                actions: [ActionItem] = [], clips: [ClipLink] = []) {
        self.meetingID = meetingID; self.title = title; self.startedAt = startedAt; self.duration = duration
        self.attendees = attendees; self.customer = customer; self.brief = brief; self.notes = notes
        self.missed = missed; self.actions = actions; self.clips = clips
    }

    /// `blockIDs` maps note ids to block ids already used for this meeting; new notes get the next free `eN`.
    public init(_ meeting: Meeting, brief: String? = nil, actions: [ActionItem] = [], customer: String? = nil,
                clips: [ClipLink] = [], blockIDs: [String: String] = [:]) {
        let segments = Dictionary(meeting.segments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Chunk refs are `segmentID#n`; the excerpt starts where its segment does.
        func excerpts(_ refs: [String]?) -> [Excerpt] {
            var seen = Set<String>()
            return (refs ?? []).compactMap { ref -> Excerpt? in
                let id = ref.components(separatedBy: "#").first ?? ref
                guard let segment = segments[id] ?? segments[meeting.resolvedSegmentID(id)], seen.insert(id).inserted else { return nil }
                return Excerpt(seconds: segment.start, segment: segment.id)
            }.sorted { $0.seconds < $1.seconds }
        }
        var used = Set(blockIDs.values)
        var next = (blockIDs.values.compactMap { Int($0.dropFirst()) }.max() ?? 0) + 1
        let notes = (meeting.notes ?? []).compactMap { note -> NoteLine? in
            let text = note.text + (note.line.text.map { "\n  " + $0 } ?? "")
            guard !text.isEmpty else { return nil }
            var block = blockIDs[note.id]
            if block == nil {
                while used.contains("e\(next)") { next += 1 }
                block = "e\(next)"; used.insert(block!); next += 1
            }
            return NoteLine(id: note.id, markdown: text, blockID: block!, sources: excerpts(note.line.evidence))
        }
        self.init(meetingID: meeting.id, title: meeting.title, startedAt: meeting.startedAt,
                  duration: meeting.endedAt.map { $0.timeIntervalSince(meeting.startedAt) },
                  attendees: meeting.attendees ?? Self.namedVoices(meeting), customer: customer, brief: brief ?? meeting.brief, notes: notes,
                  missed: (meeting.missedTopics ?? []).map { Topic(topic: $0.topic, text: $0.text, sources: excerpts($0.excerptRefs)) },
                  actions: actions.isEmpty ? APIShapes.actionItems(meeting).map { ActionItem(text: $0.text) } : actions, clips: clips)
        finalized = meeting.retention == "finalized" || meeting.retention == "purged"
    }

    /// People the user named, in order of first speech. "You" and unnamed speakers aren't people pages.
    public static func namedVoices(_ meeting: Meeting) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for segment in meeting.orderedSegments {
            guard let name = meeting.assignment(for: segment)?.name.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, name.lowercased() != "you", seen.insert(name.lowercased()).inserted else { continue }
            out.append(name)
        }
        return out
    }
}

/// Renders write-ups and merges updates into a note the user may have edited.
///
/// WorkScribe owns a fixed set of frontmatter keys and the regions between `<!-- workscribe:begin NAME -->` and
/// `<!-- workscribe:end NAME HASH -->`; HASH is what WorkScribe last wrote there. An update replaces a region only
/// when its text still hashes to HASH (the user hasn't touched it). A region the user edited is kept, and if
/// WorkScribe has something different to say, that is a conflict: the caller writes the full new version beside the
/// note. A region the user deleted stays deleted. Everything outside regions is the user's and is never rewritten.
public enum VaultWriter {
    /// Frontmatter keys WorkScribe keeps current. `tags` is seeded on creation and then left to the user.
    public static let ownedKeys = ["workscribe", "workscribe_id", "type", "date", "duration", "attendees", "customer", "recording"]
    public static let regionNames = ["title", "brief", "notes", "missed", "actions", "clips"]

    public static func dayString(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    public static func durationString(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        return minutes >= 60 ? String(format: "%dh %02dm", minutes / 60, minutes % 60) : "\(minutes)m"
    }

    public static func clockString(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%02d:%02d", value / 60, value % 60)
    }

    /// `[[People/Name]]`.
    public static func personLink(_ name: String) -> String { "[[People/\(VaultPaths.fileName(name))]]" }

    public static func ownedFrontmatter(_ writeUp: MeetingWriteUp, timeZone: TimeZone) -> Frontmatter {
        var front = Frontmatter()
        front["workscribe_id"] = .string(writeUp.meetingID)
        front["type"] = .string("meeting")
        front["date"] = .string(dayString(writeUp.startedAt, timeZone: timeZone))
        if let duration = writeUp.duration { front["duration"] = .string(durationString(duration)) }
        front["attendees"] = .list(writeUp.attendees.map(personLink))
        if let customer = writeUp.customer?.trimmingCharacters(in: .whitespaces), !customer.isEmpty {
            front["customer"] = .string("[[\(VaultPaths.fileName(customer))]]")
        }
        if !writeUp.finalized { front["recording"] = .string(WorkScribeLink.meeting(id: writeUp.meetingID, seconds: nil, segment: nil).url.absoluteString) }
        return front
    }

    public static func regions(_ writeUp: MeetingWriteUp, timeZone: TimeZone) -> [(name: String, content: String)] {
        let title = "# " + Markdown.inlineSafe(writeUp.title, limit: 300)
        let brief = (["## Brief"] + (writeUp.brief.map { [$0.trimmingCharacters(in: .whitespacesAndNewlines)] } ?? []))
        func links(_ sources: [MeetingWriteUp.Excerpt]) -> String {
            guard !writeUp.finalized else { return "" }
            return sources.prefix(4).map { excerpt in
                let url = WorkScribeLink.meeting(id: writeUp.meetingID, seconds: excerpt.seconds, segment: excerpt.segment).url
                return " [\(clockString(excerpt.seconds))](\(url.absoluteString))"
            }.joined()
        }
        let notes = ["## Notes"] + writeUp.notes.map { note in
            "- " + note.markdown + links(note.sources) + (writeUp.finalized ? "" : " ^" + note.blockID)
        }
        let missed = ["## Missed topics"] + writeUp.missed.map { topic in
            (topic.topic.isEmpty ? "- \(topic.text)" : "- **\(topic.topic):** \(topic.text)") + links(topic.sources)
        }
        let actions = ["## Action items"] + writeUp.actions.map { item in
            var line = "- [\(item.done ? "x" : " ")] "
            if let owner = item.owner?.trimmingCharacters(in: .whitespaces), !owner.isEmpty { line += personLink(owner) + ": " }
            line += item.text.replacingOccurrences(of: "\n", with: " ")
            if let due = item.due { line += " 📅 " + due }
            return line
        }
        let clips = ["## Clips & attachments"] + writeUp.clips.map { clip in
            var line = "- "
            if let offset = clip.offset { line += clockString(offset) + " " }
            line += "[[\(clip.path)|\(Markdown.inlineSafe(clip.title))]]"
            if let site = clip.site, !site.isEmpty { line += " · " + Markdown.inlineSafe(site, limit: 80) }
            return line
        }
        return [("title", title), ("brief", brief.joined(separator: "\n")), ("notes", notes.joined(separator: "\n")),
                ("missed", missed.joined(separator: "\n")), ("actions", actions.joined(separator: "\n")),
                ("clips", clips.joined(separator: "\n"))]
    }

    /// The whole note, as first written.
    public static func render(_ writeUp: MeetingWriteUp, timeZone: TimeZone = .current) -> String {
        var front = ownedFrontmatter(writeUp, timeZone: timeZone)
        front["tags"] = .list(["meeting"])
        var lines = ["---", front.render(), "---", frontmatterMarker(ownedFrontmatter(writeUp, timeZone: timeZone))]
        for (index, region) in regions(writeUp, timeZone: timeZone).enumerated() {
            if index > 0 { lines.append("") }
            lines.append(contentsOf: block(region.name, region.content))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func block(_ name: String, _ content: String) -> [String] {
        ["<!-- workscribe:begin \(name) -->", content, "<!-- workscribe:end \(name) \(hash(content)) -->"]
    }

    static func frontmatterMarker(_ owned: Frontmatter) -> String {
        "<!-- workscribe:frontmatter \(hash(canonical(owned))) -->"
    }

    /// Owned keys only, in a fixed order: what the frontmatter hash covers. Formatting changes don't count as edits.
    static func canonical(_ front: Frontmatter) -> String {
        ownedKeys.compactMap { key in
            front[key].map { value in key + "=" + value.strings.joined(separator: "\u{1F}") }
        }.joined(separator: "\u{1E}")
    }

    /// Short SHA-256 of text with line endings and trailing whitespace normalized.
    public static func hash(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
            .joined(separator: "\n").trimmingCharacters(in: .newlines)
        return sha256(Data(normalized.utf8)).prefix(12).description
    }

    static func sha256(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Merge

    public struct MergeResult: Equatable, Sendable {
        /// The note with every update WorkScribe may make.
        public var text: String
        /// Sections WorkScribe had new content for but the user had edited ("frontmatter", "notes", …).
        public var conflicts: [String]
        public var changed: Bool
    }

    public static func merge(existing: String, update writeUp: MeetingWriteUp, timeZone: TimeZone = .current) -> MergeResult {
        let original = existing.replacingOccurrences(of: "\r\n", with: "\n")
        var conflicts: [String] = []
        let (yaml, body) = Frontmatter.split(original)
        let newOwned = ownedFrontmatter(writeUp, timeZone: timeZone)

        // Frontmatter.
        var frontText = yaml.map { "---\n\($0)\n---\n" } ?? ""
        var bodyLines = body.components(separatedBy: "\n")
        let markerPattern = #"^<!-- workscribe:frontmatter ([0-9a-f]+) -->$"#
        if let yaml, let markerIndex = bodyLines.firstIndex(where: { Markdown.match(markerPattern, $0) != nil }),
           let recorded = Markdown.match(markerPattern, bodyLines[markerIndex])?[1] {
            let current = Frontmatter.parse(yaml)
            let currentHash = hash(canonical(current))
            let newHash = hash(canonical(newOwned))
            if currentHash == newHash {
                if newHash != recorded { bodyLines[markerIndex] = frontmatterMarker(newOwned) }
            } else if currentHash == recorded {
                if newHash != recorded {
                    var merged = Frontmatter()
                    for entry in current.entries {
                        if ownedKeys.contains(entry.key) {
                            if let value = newOwned[entry.key] { merged.entries.append(.init(entry.key, value)) }
                        } else { merged.entries.append(entry) }
                    }
                    for entry in newOwned.entries where merged[entry.key] == nil { merged.entries.append(entry) }
                    frontText = "---\n\(merged.render())\n---\n"
                    bodyLines[markerIndex] = frontmatterMarker(newOwned)
                }
            } else if newHash != recorded {
                conflicts.append("frontmatter")
            }
        }

        // Regions.
        let newRegions = Dictionary(regions(writeUp, timeZone: timeZone).map { ($0.name, $0.content) }, uniquingKeysWith: { a, _ in a })
        var out: [String] = []
        var index = 0
        while index < bodyLines.count {
            let line = bodyLines[index]
            guard let begin = Markdown.match(#"^<!-- workscribe:begin ([a-z]+) -->$"#, line), let name = begin[1],
                  let endIndex = bodyLines[(index + 1)...].firstIndex(where: { $0.hasPrefix("<!-- workscribe:end \(name) ") }),
                  let recorded = Markdown.match(#"^<!-- workscribe:end [a-z]+ ([0-9a-f]+) -->$"#, bodyLines[endIndex])?[1] else {
                out.append(line); index += 1; continue
            }
            let current = bodyLines[(index + 1)..<endIndex].joined(separator: "\n")
            // Unedited, or the user already wrote exactly what WorkScribe would.
            if let replacement = newRegions[name], hash(current) == recorded || hash(current) == hash(replacement) {
                out.append(contentsOf: block(name, replacement))
            } else {
                if let replacement = newRegions[name], hash(replacement) != recorded { conflicts.append(name) }
                out.append(contentsOf: bodyLines[index...endIndex])
            }
            index = endIndex + 1
        }
        let text = frontText + out.joined(separator: "\n")
        return MergeResult(text: text, conflicts: conflicts, changed: text != original)
    }
}

/// File and link names for vault notes.
public enum VaultPaths {
    /// A note name Obsidian and the filesystem both accept: no `/ \ : * ? " < > | # ^ [ ]`, no leading dot, ≤ 120 chars.
    public static func fileName(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: #"[/\\:*?"<>|#^\[\]\n\r\t]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        if cleaned.count > 120 { cleaned = String(cleaned.prefix(120)).trimmingCharacters(in: .whitespaces) }
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}
