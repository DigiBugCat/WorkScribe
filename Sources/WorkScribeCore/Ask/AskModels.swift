import Foundation

/// One retrievable moment for Ask: a span of a meeting, a page of a document, a window of a recording, an attached
/// note. Codable (unlike `SearchHit`) so cited moments persist with the conversation.
public struct AskMoment: Codable, Equatable, Sendable, Identifiable {
    /// Stable identity for de-duplication: "chunk:<id>" for index hits, "live:<segment>" for the live meeting.
    public var id: String
    /// "meeting" or "file" (`SourceKind`).
    public var sourceKind: String
    /// Meeting ID or absolute file path.
    public var ref: String
    public var title: String?
    /// `ChunkKind` raw value.
    public var kind: String
    public var start: Double?
    public var end: Double?
    public var page: Int?
    public var anchorSegment: String?
    public var speakers: [String]
    /// The passage the answer model reads (trimmed when the prompt is built).
    public var text: String
    /// A short excerpt for display, with «matched» words when keyword search found it.
    public var snippet: String?
    /// The moment came from something attached to this conversation or meeting.
    public var attached: Bool
    /// Screen moments: an absolute path to a thumbnail, and "App — Window".
    public var thumbnail: String?
    public var window: String?
    /// `obsidian://open?…` for vault notes and web clips.
    public var obsidianLink: String?

    public init(id: String, sourceKind: String, ref: String, title: String?, kind: String, start: Double? = nil,
                end: Double? = nil, page: Int? = nil, anchorSegment: String? = nil, speakers: [String] = [],
                text: String, snippet: String? = nil, attached: Bool = false) {
        self.id = id; self.sourceKind = sourceKind; self.ref = ref; self.title = title; self.kind = kind
        self.start = start; self.end = end; self.page = page; self.anchorSegment = anchorSegment
        self.speakers = speakers; self.text = text; self.snippet = snippet; self.attached = attached
    }

    public init(hit: SearchHit, attached: Bool = false) {
        self.init(id: "chunk:\(hit.chunkID)", sourceKind: hit.sourceKind.rawValue, ref: hit.ref, title: hit.title,
                  kind: hit.kind.rawValue, start: hit.start, end: hit.end, page: hit.page,
                  anchorSegment: hit.anchorSegment, speakers: hit.speakers, text: hit.text ?? hit.snippet ?? "",
                  snippet: hit.snippet, attached: attached)
        thumbnail = hit.thumbnail; window = hit.window; obsidianLink = hit.obsidianURL?.absoluteString
    }

    public var isMeeting: Bool { sourceKind == SourceKind.meeting.rawValue }

    /// Where a citation row opens: the meeting at the moment, or the file at its page or time.
    public var link: WorkScribeLink {
        isMeeting ? .meeting(id: ref, seconds: start, segment: anchorSegment) : .file(path: ref, page: page, seconds: start)
    }

    /// "Priya · 27:30", "p.14", "at 03:05": what locates the moment inside its source.
    public var locator: String {
        var parts: [String] = []
        if isMeeting, !speakers.isEmpty { parts.append(speakers.joined(separator: ", ")) }
        if let page { parts.append("p.\(page)") }
        if let start { parts.append((isMeeting ? "" : "at ") + Self.clock(start)) }
        return parts.joined(separator: " · ")
    }

    /// The source's display name: the meeting title, or the file name.
    public var sourceName: String {
        if let title, !title.isEmpty { return title }
        return isMeeting ? "Meeting" : (ref as NSString).lastPathComponent
    }

    public static func clock(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%02d:%02d", value / 60, value % 60)
    }
}

/// A numbered source an answer cites.
public struct AskCitation: Codable, Equatable, Sendable, Identifiable {
    public var number: Int
    public var moment: AskMoment
    public var id: Int { number }
    public init(number: Int, moment: AskMoment) { self.number = number; self.moment = moment }
}

public struct AskMessage: Codable, Equatable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public enum State: String, Codable, Sendable {
        /// Retrieving or generating.
        case working
        /// A written answer with citations.
        case answered
        /// No answer model: the moments found are shown without an answer.
        case momentsOnly
        /// Nothing relevant was found.
        case empty
        case failed
    }
    public var id: String
    public var role: Role
    public var text: String
    public var createdAt: Date
    public var state: State
    public var citations: [AskCitation]
    /// Why there's no answer, or which model wrote it ("Qwen 3.5 · on this Mac").
    public var detail: String?
    public var trace: AITrace?

    public init(id: String = UUID().uuidString, role: Role, text: String, createdAt: Date = Date(),
                state: State = .answered, citations: [AskCitation] = [], detail: String? = nil) {
        self.id = id; self.role = role; self.text = text; self.createdAt = createdAt; self.state = state
        self.citations = citations; self.detail = detail
    }
}

/// A chat over meetings and files, with what was attached to it.
public struct Conversation: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var pinned: Bool
    /// "main" or "quick" (started from the quick-ask panel).
    public var origin: String
    /// Retrieval looks in this meeting first (set when asked during a recording, or from a meeting page).
    public var scopeMeetingID: String?
    public var messages: [AskMessage]
    public var attachments: [Attachment]

    public init(id: String = UUID().uuidString, title: String = "New chat", createdAt: Date = Date(), pinned: Bool = false,
                origin: String = "main", scopeMeetingID: String? = nil, messages: [AskMessage] = [], attachments: [Attachment] = []) {
        self.id = id; self.title = title; self.createdAt = createdAt; self.updatedAt = createdAt; self.pinned = pinned
        self.origin = origin; self.scopeMeetingID = scopeMeetingID; self.messages = messages; self.attachments = attachments
    }

    /// The first question, shortened, names the chat.
    public static func title(for question: String) -> String {
        let flat = question.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard flat.count > 60 else { return flat.isEmpty ? "New chat" : flat }
        let cut = flat.prefix(60)
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return word + "…"
    }
}
