import Foundation

/// The local API's endpoints (docs/api/local-api.md).
public enum APIRoute: Equatable, Sendable {
    case status
    case startRecording, stopRecording, resumeRecording(String)
    case meetings
    case meeting(String)
    case done(String)
    case grabMoment(String)
    case openDocument(String), syncDocument(String), finalizeDocument(String)
    case addNote(meetingID: String)
    case editNote(meetingID: String, noteID: String)
    case events
    case rewriteLine(documentID: String, blockID: String)
    case ask
    case search
    case attachments

    /// The route for a method and path, or the HTTP status to answer with (404 unknown path, 405 wrong method).
    public static func match(method: String, path: String) -> Result<APIRoute, APIRouteError> {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.first == "v1" else { return .failure(.notFound) }
        let rest = Array(parts.dropFirst())
        func only(_ allowed: String, _ route: APIRoute) -> Result<APIRoute, APIRouteError> {
            method == allowed ? .success(route) : .failure(.methodNotAllowed)
        }
        switch rest.count {
        case 1:
            switch rest[0] {
            case "status": return only("GET", .status)
            case "meetings": return only("GET", .meetings)
            case "events": return only("GET", .events)
            case "ask": return only("POST", .ask)
            case "search": return only("POST", .search)
            case "attachments": return only("POST", .attachments)
            default: return .failure(.notFound)
            }
        case 2 where rest[0] == "recording":
            switch rest[1] {
            case "start": return only("POST", .startRecording)
            case "stop": return only("POST", .stopRecording)
            default: return .failure(.notFound)
            }
        case 2 where rest[0] == "meetings":
            return only("GET", .meeting(rest[1]))
        case 3 where rest[0] == "meetings" && rest[2] == "resume":
            return only("POST", .resumeRecording(rest[1]))
        case 3 where rest[0] == "meetings" && rest[2] == "grab-moment":
            return only("POST", .grabMoment(rest[1]))
        case 3 where rest[0] == "meetings" && rest[2] == "document":
            if method == "POST" { return .success(.openDocument(rest[1])) }
            return only("PATCH", .syncDocument(rest[1]))
        case 3 where rest[0] == "meetings" && rest[2] == "finalize":
            return only("POST", .finalizeDocument(rest[1]))
        case 3 where rest[0] == "meetings" && rest[2] == "done":
            return only("POST", .done(rest[1]))
        case 3 where rest[0] == "meetings" && rest[2] == "notes":
            return only("POST", .addNote(meetingID: rest[1]))
        case 4 where rest[0] == "meetings" && rest[2] == "notes":
            return only("PATCH", .editNote(meetingID: rest[1], noteID: rest[3]))
        case 5 where rest[0] == "documents" && rest[2] == "blocks" && rest[4] == "rewrite":
            return only("POST", .rewriteLine(documentID: rest[1], blockID: rest[3]))
        default:
            return .failure(.notFound)
        }
    }
}

public enum APIRouteError: Error, Equatable, Sendable {
    case notFound, methodNotAllowed
    public var status: Int { self == .notFound ? 404 : 405 }
}

// MARK: Request bodies

public struct APIStartBody: Codable, Sendable {
    public var title: String?
    /// "recorder" (this Mac's audio) or "zoom-captions"; nil uses the app's setting.
    public var source: String?
}
public struct APINoteBody: Codable, Sendable {
    public var text: String
    /// Seconds into the recording; defaults to now for the live meeting.
    public var at: Double?
    public var fromAnswer: NoteAnswerOrigin?
    public var fromMissedTopic: MissedTopicOrigin?
}
public struct MissedTopicOrigin: Codable, Sendable { public var topic: String }
public struct APINotePatch: Decodable, Sendable {
    public var text: String?
    public var enhanced: NoteEnhancementText?
    public var rewrite: Bool?
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        enhanced = try c.decodeIfPresent(NoteEnhancementText.self, forKey: .enhanced)
        rewrite = try c.decodeIfPresent(Bool.self, forKey: .rewrite)
        guard [text != nil, enhanced != nil, rewrite == true].filter({ $0 }).count == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Give exactly one of text, enhanced, or rewrite:true"))
        }
    }
    private enum CodingKeys: String, CodingKey { case text, enhanced, rewrite }
}
public struct APIAttachmentRef: Codable, Sendable, Equatable { public var path: String?; public var text: String? }
public struct APIAskBody: Codable, Sendable {
    public var question: String
    public var meetingId: String?
    public var conversationId: String?
    public var attachments: [APIAttachmentRef]?
}
public struct APISearchBody: Codable, Sendable {
    public var query: String
    /// `ChunkKind` raw values: meetingSegment, document, audio, video, image.
    public var kinds: [String]?
    public var limit: Int?
}
public struct APIAttachBody: Codable, Sendable {
    public var meetingId: String?
    public var conversationId: String?
    public var path: String?
    public var text: String?
}

// MARK: Response shapes

public struct APIStatus: Codable, Equatable, Sendable {
    public struct Sources: Codable, Equatable, Sendable {
        public var mic: Bool; public var system: Bool; public var screen: Bool
        public init(mic: Bool, system: Bool, screen: Bool) { self.mic = mic; self.system = system; self.screen = screen }
    }
    public struct Permissions: Codable, Equatable, Sendable {
        public var screenRecording: Bool; public var microphone: Bool
        public init(screenRecording: Bool, microphone: Bool) { self.screenRecording = screenRecording; self.microphone = microphone }
    }
    /// The answer model: provider "local" or "none" (moments only).
    public struct Model: Codable, Equatable, Sendable {
        public var provider: String; public var name: String
        public init(provider: String, name: String) { self.provider = provider; self.name = name }
    }
    public var recording: Bool
    /// ready, starting, recording, finalizing, error, preview
    public var phase: String
    public var meetingId: String?
    public var title: String?
    public var startedAt: Date?
    /// Seconds since `startedAt` while recording, else 0.
    public var elapsed: Double
    public var sources: Sources
    public var permissions: Permissions
    public var warming: Bool
    public var message: String?
    public var finalizationProgress: Double?
    public var model: Model
    public init(recording: Bool, phase: String, meetingId: String?, title: String?, startedAt: Date?, elapsed: Double,
                sources: Sources, permissions: Permissions, warming: Bool, message: String?,
                model: Model = Model(provider: "none", name: ""), finalizationProgress: Double? = nil) {
        self.finalizationProgress = finalizationProgress
        self.model = model
        self.recording = recording; self.phase = phase; self.meetingId = meetingId; self.title = title; self.startedAt = startedAt
        self.elapsed = elapsed; self.sources = sources; self.permissions = permissions; self.warming = warming; self.message = message
    }
}

public struct APIMeetingSummary: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var startedAt: Date
    /// Seconds; nil while recording.
    public var duration: Double?
    public var speakers: [String]
    public var status: String
    /// The meeting's note in the vault (absolute path) and its `obsidian://` link, once written.
    public var retention: String?
    public var purgeAt: Date?
    public var vaultPath: String?
    public var obsidianLink: String?
}

public struct APISegment: Codable, Equatable, Sendable {
    public var id: String
    public var speaker: String
    public var speakerKey: String
    public var source: String
    public var start: Double
    public var end: Double
    public var text: String
    /// False for the in-progress (partial) line of the live meeting.
    public var final: Bool
}

/// An excerpt a note was enhanced from: "E1", with where it is. `hollow` marks a match by meaning only (outside the
/// typing window around the note).
public struct APIExcerpt: Codable, Equatable, Sendable {
    public var id: String
    public var match: String
    public var chunkId: String
    public var segmentId: String
    public var speaker: String
    public var start: Double
    public var end: Double
    public var text: String
    public var hollow: Bool
    public var link: String
}

public struct APILineSource: Codable, Equatable, Sendable {
    public var kind: String; public var title: String
    public var at: Double?; public var quote: String?; public var speaker: String?
    public var segmentId: String?; public var meetingId: String?; public var path: String?; public var link: String?
}
public struct APILine: Codable, Equatable, Sendable {
    public var documentId: String; public var blockId: String; public var state: Line.State
    public var text: String?; public var revision: Int; public var sources: [APILineSource]; public var reason: String?
}
public struct APINote: Codable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var at: Double?
    public var enhanced: NoteEnhancementText?
    public var state: String
    public var fromAnswer: NoteAnswerOrigin?
    public var userEdited: Bool?
    public var blockId: String?
    public var excerpts: [APIExcerpt]
    public var trace: AITrace? = nil
    public var images: [NoteImage]? = nil
    public var line: APILine? = nil
}

public struct APIMissedTopic: Codable, Equatable, Sendable {
    public var topic: String
    public var text: String
    public var excerpts: [APIExcerpt]
    public init(topic: String, text: String, excerpts: [APIExcerpt]) { self.topic = topic; self.text = text; self.excerpts = excerpts }
}

public struct APIActionItem: Codable, Equatable, Sendable {
    public var due: String? = nil
    public var text: String
    /// A named owner from the transcript-backed final pass, when stated.
    public var owner: String?
    public var askedBy: String?
    /// Supporting quotation when supplied by the source.
    public var quote: String
    public var at: Double?
    public var noteId: String
}

public struct APIMoment: Codable, Equatable, Sendable {
    public var kind: String
    public var title: String?
    public var snippet: String?
    public var meetingId: String?
    public var path: String?
    public var start: Double?
    public var end: Double?
    public var page: Int?
    public var speaker: String?
    public var thumbnail: String?
    public var link: String
    public var attached: Bool
    /// Screen moments: "App — Window".
    public var window: String?
    /// Present when the moment is a citation.
    public var number: Int?

    public init(_ moment: AskMoment, number: Int? = nil) {
        kind = APIShapes.momentKind(moment); title = moment.title ?? moment.sourceName; snippet = moment.snippet ?? String(moment.text.prefix(240))
        meetingId = moment.isMeeting ? moment.ref : nil; path = moment.isMeeting ? nil : moment.ref
        start = moment.start; end = moment.end; page = moment.page; speaker = moment.speakers.first
        thumbnail = moment.thumbnail; link = moment.obsidianLink ?? moment.link.url.absoluteString; attached = moment.attached; window = moment.window; self.number = number
    }
}

public struct APIAnswer: Codable, Equatable, Sendable {
    public var id: String
    public var done: Bool
    public var conversationId: String
    public var question: String
    public var answer: String
    public var state: String
    public var citations: [APIMoment]
    public var at: Double
    public var createdAt: Date
    public var trace: AITrace? = nil
}

public struct APIMeetingDetail: Codable, Equatable, Sendable {
    public var meeting: APIMeetingSummary
    public var segments: [APISegment]
    public var notes: [APINote]
    public var missedTopics: [APIMissedTopic]
    public var actionItems: [APIActionItem]
    public var answers: [APIAnswer]
    public var endedAt: Date? = nil
    public var attachments: [Attachment]
    /// Web clips attached to this meeting (vault-relative paths).
    public var clips: [SavedClip]
    public var document: NoteDocument?
}

public struct APIAttachmentResult: Codable, Equatable, Sendable {
    public var attachment: Attachment
    /// "conversation:<id>" or "meeting:<id>".
    public var owner: String
    public var path: String?
    public init(attachment: Attachment, owner: String, path: String?) { self.attachment = attachment; self.owner = owner; self.path = path }
}

/// Builds the JSON shapes from meetings and conversations. Pure, so it is tested without the app.
public enum APIShapes {
    public static func momentKind(_ moment: AskMoment) -> String {
        if moment.isMeeting { return moment.kind == "screen" ? "screen" : "meeting" }
        if moment.kind == "clip" { return "clip" }
        if moment.kind == "image" { return "image" }
        if moment.sourceKind == "vault" { return "note" }
        if moment.kind == "document", (moment.ref as NSString).pathExtension.lowercased() == "pdf" { return "pdf" }
        return moment.kind
    }
    public static func searchKinds(_ kinds: [String]) -> Set<ChunkKind> {
        Set(kinds.compactMap { kind in
            switch kind {
            case "meeting": return .meetingSegment
            case "pdf", "note": return .document
            default: return ChunkKind(rawValue: kind)
            }
        })
    }
    public static func summary(_ meeting: Meeting, vaultPath: String? = nil, obsidianLink: String? = nil) -> APIMeetingSummary {
        var seen = Set<String>()
        let speakers = meeting.orderedSegments.map { meeting.speakerName(for: $0) }.filter { seen.insert($0).inserted }
        return APIMeetingSummary(id: meeting.id, title: meeting.title, startedAt: meeting.startedAt,
                                 duration: meeting.endedAt.map { $0.timeIntervalSince(meeting.startedAt) },
                                 speakers: speakers, status: meeting.status, retention: meeting.retention ?? "live", purgeAt: meeting.purgeAt, vaultPath: vaultPath ?? meeting.vaultPath, obsidianLink: obsidianLink)
    }

    public static func segments(_ meeting: Meeting) -> [APISegment] {
        var out = meeting.orderedSegments.map {
            APISegment(id: $0.id, speaker: meeting.speakerName(for: $0), speakerKey: $0.speaker, source: $0.source,
                       start: $0.start, end: $0.end, text: $0.text, final: true)
        }
        let lastEnd = meeting.segments.map(\.end).max() ?? 0
        for source in meeting.partials.keys.sorted() {
            guard let text = meeting.partials[source], !text.isEmpty else { continue }
            let key = meeting.partialSpeakers?[source] ?? "\(source):unknown"
            out.append(APISegment(id: meeting.partialIDs?[source] ?? "partial:\(source)", speaker: meeting.speakerAssignments?[key]?.name ?? Meeting.originalSpeakerName(key),
                                  speakerKey: key, source: source, start: lastEnd, end: lastEnd, text: text, final: false))
        }
        return out
    }

    /// Excerpts labelled E1, E2… per note in reference order.
    public static func excerpts(_ refs: [String], note at: Double?, meeting: Meeting, chunks: [String: TranscriptChunk]) -> [APIExcerpt] {
        refs.enumerated().compactMap { number, ref in
            let segmentID = ref.components(separatedBy: "#")[0]
            guard let chunk = chunks[ref] ?? chunks[meeting.resolvedSegmentID(segmentID) + "#0"] else { return nil }
            return APIExcerpt(id: "E\(number + 1)", match: at == nil || !(at.map { chunk.start <= $0 + 30 && chunk.end >= $0 - 90 } ?? false) ? "meaning" : "time+meaning", chunkId: ref, segmentId: chunk.segmentID, speaker: chunk.speaker,
                              start: chunk.start, end: chunk.end, text: chunk.text,
                              hollow: at == nil || !(at.map { chunk.start <= $0 + 30 && chunk.end >= $0 - 90 } ?? false),
                              link: WorkScribeLink.meeting(id: meeting.id, seconds: chunk.start, segment: chunk.segmentID).url.absoluteString)
        }
    }

    public static func note(_ note: Note, meeting: Meeting, chunks: [String: TranscriptChunk], blockId: String? = nil) -> APINote {
        var trace = note.trace
        if trace != nil { trace?.revisions = note.line.history.map { TraceRevision(version: $0.version, text: $0.text, reason: $0.reason, at: $0.at) } }
        return APINote(id: note.id, text: note.text, at: note.createdAt,
                enhanced: note.line.text.map(NoteEnhancementText.init(markdown:)),
                state: note.line.state.rawValue,
                fromAnswer: note.fromAnswer, userEdited: note.line.owned, blockId: meeting.retention == "finalized" || meeting.retention == "purged" ? nil : blockId,
                excerpts: excerpts(note.line.evidence ?? [], note: note.createdAt, meeting: meeting, chunks: chunks), trace: trace, images: note.images, line: line(note, meeting: meeting, chunks: chunks, blockId: blockId))
    }

    public static func line(_ note: Note, meeting: Meeting, chunks: [String: TranscriptChunk], blockId: String? = nil) -> APILine {
        var sources = excerpts(note.line.evidence ?? [], note: note.createdAt, meeting: meeting, chunks: chunks).map {
            APILineSource(kind: "meeting", title: $0.speaker, at: $0.start, quote: $0.text, speaker: $0.speaker,
                          segmentId: $0.segmentId, meetingId: meeting.id, link: $0.link)
        }
        sources += (note.trace?.sources ?? []).map {
            APILineSource(kind: $0.kind == "background" ? "note" : $0.kind, title: $0.title, quote: $0.text, link: $0.link)
        }
        sources += (note.images ?? []).filter { !$0.evidence.isEmpty }.map {
            APILineSource(kind: "image", title: $0.target, quote: $0.evidence, path: $0.path,
                          link: WorkScribeLink.file(path: $0.path ?? $0.target, page: nil, seconds: nil).url.absoluteString)
        }
        if meeting.retention == "purged" || meeting.retention == "purging" { sources = [] }
        let text = note.line.text.map { value in
            let parsed = NoteEnhancementText(markdown: value)
            return [parsed.topic, parsed.text].filter { !$0.isEmpty }.joined(separator: " ")
        }
        return APILine(documentId: meeting.id, blockId: blockId ?? note.id, state: note.line.state, text: text,
                       revision: note.line.revision ?? 0, sources: sources,
                       reason: meeting.retention == "purged" ? "Sources faded with the transcript" : nil)
    }

    public static func chunkMap(_ meeting: Meeting) -> [String: TranscriptChunk] {
        let chunks = Chunker.transcript(meeting)
        var map = Dictionary(chunks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Persisted pre-rebuild citations still point to segment#piece. New citations use content IDs.
        var pieces: [String: Int] = [:]
        for chunk in chunks {
            let piece = pieces[chunk.segmentID, default: 0]; pieces[chunk.segmentID] = piece + 1
            map[chunk.segmentID + "#\(piece)"] = chunk
        }
        for (old, current) in meeting.transcriptAliases ?? [:] {
            if let replacement = map[current + "#0"] { map[old + "#0"] = replacement }
        }
        return map
    }

    public static func actionItems(_ meeting: Meeting) -> [APIActionItem] {
        (meeting.actionItems ?? []).map { item in
            APIActionItem(due: item.due, text: item.text, owner: item.owner, askedBy: nil, quote: "", at: nil, noteId: "")
        }
    }

    public static func answers(_ conversations: [Conversation], meetingID: String, startedAt: Date) -> [APIAnswer] {
        conversations.filter { $0.scopeMeetingID == meetingID }.flatMap { conversation -> [APIAnswer] in
            var out: [APIAnswer] = []
            var question = ""
            for message in conversation.messages {
                if message.role == .user { question = message.text; continue }
                guard message.state != .working else { continue }
                out.append(APIAnswer(id: message.id, done: true, conversationId: conversation.id, question: question, answer: message.text, state: message.state.rawValue,
                                     citations: message.citations.map { APIMoment($0.moment, number: $0.number) }, at: max(0, message.createdAt.timeIntervalSince(startedAt)), createdAt: message.createdAt, trace: message.trace))
            }
            return out
        }.sorted { $0.createdAt < $1.createdAt }
    }

    public static func detail(_ meeting: Meeting, conversations: [Conversation], attachments: [Attachment], vaultPath: String? = nil,
                              obsidianLink: String? = nil, clips: [SavedClip] = [], blockIDs: [String: String] = [:]) -> APIMeetingDetail {
        let chunks = chunkMap(meeting)
        return APIMeetingDetail(
            meeting: summary(meeting, vaultPath: vaultPath, obsidianLink: obsidianLink), segments: segments(meeting),
            notes: (meeting.notes ?? []).map { note($0, meeting: meeting, chunks: chunks, blockId: blockIDs[$0.id]) },
            missedTopics: (meeting.missedTopics ?? []).map {
                APIMissedTopic(topic: $0.topic, text: $0.text, excerpts: excerpts($0.excerptRefs, note: nil, meeting: meeting, chunks: chunks))
            },
            actionItems: actionItems(meeting), answers: answers(conversations, meetingID: meeting.id, startedAt: meeting.startedAt), endedAt: meeting.endedAt, attachments: attachments,
            clips: clips, document: meeting.document)
    }
}
