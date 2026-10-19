import Foundation

public struct SourceID: Hashable, Sendable {
    public enum Kind: String, Sendable { case meeting, vault, folder, clip, screen, attachment }
    public var kind: Kind
    public var ref: String
    public init(_ kind: Kind, _ ref: String) { self.kind = kind; self.ref = ref }
    var key: String { kind.rawValue + ":" + ref }
    var storageKind: SourceKind {
        switch kind { case .meeting, .screen: .meeting; case .vault, .clip: .vault; case .folder, .attachment: .file }
    }
}

/// Ordered source material; speaker labels are attributes, never embedded words.
public struct Passage: Sendable, Equatable {
    public var source: SourceID
    public var anchor: String
    public var text: String
    public var context: String?
    public var start: Double?
    public var end: Double?
    public var speaker: String?
    public var page: Int?
    public var kind: ChunkKind
    public var modality: Modality
    public var track: String?
    public var speakerKey: String?
    public var segmentIDs: [String]
    public var thumbnail: String?
    public var window: String?
    public var vector: [Float]?
    public init(text: String, page: Int? = nil, source: SourceID = SourceID(.folder, ""), anchor: String = "",
                context: String? = nil, start: Double? = nil, end: Double? = nil, speaker: String? = nil,
                kind: ChunkKind = .document, modality: Modality = .text, track: String? = nil,
                speakerKey: String? = nil, segmentIDs: [String] = [], thumbnail: String? = nil,
                window: String? = nil, vector: [Float]? = nil) {
        self.text = text; self.page = page; self.source = source; self.anchor = anchor; self.context = context
        self.start = start; self.end = end; self.speaker = speaker; self.kind = kind; self.modality = modality
        self.track = track; self.speakerKey = speakerKey; self.segmentIDs = segmentIDs
        self.thumbnail = thumbnail; self.window = window; self.vector = vector
    }
}

public struct SourceRevision: Sendable {
    public var source: SourceID
    public var revision: Int
    public var passages: [Passage]
    public var title: String?
    public var root: String?
    public var startedAt: Date?
    public var fingerprint: String
    public var contentHash: String?
    public var voiceRevision: Int?
    public var state = "indexed"
    public var detail: String?
    public var metadata: [String: String] = [:]
    public init(source: SourceID, revision: Int = 0, passages: [Passage], title: String? = nil,
                root: String? = nil, startedAt: Date? = nil, fingerprint: String = "", contentHash: String? = nil,
                voiceRevision: Int? = nil) {
        self.source = source; self.revision = revision; self.passages = passages; self.title = title
        self.root = root; self.startedAt = startedAt; self.fingerprint = fingerprint; self.contentHash = contentHash
        self.voiceRevision = voiceRevision
    }
}

public enum MeetingSource {
    public static func revision(_ meeting: Meeting) -> SourceRevision {
        let source = SourceID(.meeting, meeting.id)
        let passages = meeting.settledSegments.map { segment in
            Passage(text: segment.text, source: source, anchor: segment.id, start: segment.start, end: segment.end,
                    speaker: meeting.speakerName(for: segment), kind: .meetingSegment, track: segment.source,
                    speakerKey: segment.speaker, segmentIDs: [segment.id])
        }
        return SourceRevision(source: source, passages: passages, title: meeting.title, startedAt: meeting.startedAt,
                              fingerprint: fingerprint(meeting), voiceRevision: meeting.voiceRevision)
    }
    public static func fingerprint(_ meeting: Meeting, screen: [ScreenMoment] = []) -> String {
        var hash = StableHash()
        hash.add(meeting.title)
        for segment in meeting.settledSegments {
            hash.add(segment.id); hash.add(segment.text); hash.add(String(segment.start)); hash.add(String(segment.end))
        }
        if !screen.isEmpty { ScreenSource.add(screen, to: &hash) }
        return "passages2:\(meeting.segments.count)" + (screen.isEmpty ? "" : "+s\(screen.count)") + ":" + hash.hex
    }
}

/// Markdown parsing establishes provenance boundaries; only Chunker splits their contents.
public enum MarkdownSource {
    public static func passages(_ markdown: String, title: String, source: SourceID) -> [Passage] {
        var lines: [String] = [], fence: String?
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence { if trimmed.hasPrefix(open) { fence = nil } }
            else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fence = String(trimmed.prefix(3)) }
            else if line.range(of: #"^\s*(?:[-*+] |[0-9]+[.)] )"#, options: .regularExpression) != nil { lines.append("") }
            lines.append(line)
        }
        var path: [(Int, String)] = [], result: [Passage] = []
        var ordinals: [String: Int] = [:]
        for section in VaultDocument.parse(lines.joined(separator: "\n")).sections {
            if let heading = section.heading { path.removeAll { $0.0 >= section.level }; path.append((section.level, heading)) }
            let context = ([title] + path.map(\.1).filter { $0 != title }).filter { !$0.isEmpty }.joined(separator: " > ")
            for block in section.text.components(separatedBy: "\n\n") {
                let text = block.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let ordinal = ordinals[context, default: 0]; ordinals[context] = ordinal + 1
                result.append(Passage(text: text, source: source, anchor: context + "#\(ordinal)", context: context,
                                      kind: source.kind == .clip ? .clip : .document))
            }
        }
        return result
    }
}
