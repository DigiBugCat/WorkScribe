import Foundation

public struct Segment: Codable, Identifiable {
    public var id: String
    public var source: String
    public var speaker: String
    public var start: Double
    public var end: Double
    public var text: String
    public init(source: String, speaker: String, start: Double, end: Double, text: String) {
        id = UUID().uuidString; self.source = source; self.speaker = speaker
        self.start = start; self.end = end; self.text = text
    }
}

public struct Meeting: Codable, Identifiable {
    public var id: String
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var status: String
    public var segments: [Segment]
    public var partials: [String: String]
    public var partialSpeakers: [String: String]?
    public var failure: String?
    // Missing on legacy recordings: treat those names as manually chosen.
    public var titleOrigin: String?
    public var titleFinal: Bool?
    public var recordingTrigger: String?
    public var sourceOffsets: [String: Double]?
    public var speakerAssignments: [String: SpeakerAssignment]?
    public var segmentAssignments: [String: SpeakerAssignment]?
    public var speakerSuggestions: [String: VoiceSuggestion]?
    public var voiceRevision: Int?
    public func assignment(for segment: Segment) -> SpeakerAssignment? {
        let result = segmentAssignments?[segment.id] ?? speakerAssignments?[segment.speaker]
        return result?.name.isEmpty == false ? result : nil
    }
    public func speakerName(for segment: Segment) -> String {
        assignment(for: segment)?.name ?? Self.originalSpeakerName(segment.speaker)
    }
    public static func originalSpeakerName(_ speaker: String) -> String {
        guard let number = speaker.components(separatedBy: "speaker-").last.flatMap(Int.init), number > 0 else { return "Unidentified speaker" }
        return "Speaker \(number)"
    }
    public init(title: String, titleOrigin: String = "manual") {
        id = UUID().uuidString; self.title = title; startedAt = Date()
        status = "recording"; segments = []; partials = [:]
        self.titleOrigin = titleOrigin
    }
    public var orderedSegments: [Segment] { segments.sorted { $0.start < $1.start } }
}

public struct MeetingStore {
    public let root: URL
    public init(root: URL? = nil) {
        self.root = root ?? ProcessInfo.processInfo.environment["WORKSCRIBE_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WorkScribe/Meetings")
    }
    public func directory(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw StoreError.invalidID }
        return root.appendingPathComponent(id, isDirectory: true)
    }
    public func save(_ meeting: Meeting) throws {
        let folder = try directory(meeting.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let file = folder.appendingPathComponent("transcript.json")
        try encoder.encode(meeting).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func load(_ id: String) throws -> Meeting {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Meeting.self, from: Data(contentsOf: directory(id).appendingPathComponent("transcript.json")))
    }
    public func list() -> [Meeting] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { try? load($0.lastPathComponent) }.sorted { $0.startedAt > $1.startedAt }
    }
    public enum StoreError: Error { case invalidID }
}

/// Final word timestamps are stream-relative. Preserve the audio-source namespace:
/// speaker 1 on the microphone is not necessarily speaker 1 on system audio.
public enum TranscriptParser {
    public static func partialSpeaker(event: [String: Any], source: String) -> String? {
        guard let words = event["words"] as? [[String: Any]], !words.isEmpty else { return nil }
        let labels = words.compactMap { $0["speaker"] as? Int }
        guard labels.count == words.count, let first = labels.first, first > 0,
              labels.allSatisfy({ $0 == first }) else { return nil }
        return "\(source):speaker-\(first)"
    }
    public static func segments(event: [String: Any], source: String, offset: Double, fallbackStart: Double) -> [Segment] {
        let words = event["words"] as? [[String: Any]] ?? []
        var result: [Segment] = []
        for word in words {
            guard let text = word["word"] as? String, !text.isEmpty,
                  let start = word["start"] as? Double, let end = word["end"] as? Double else { continue }
            let speaker = (word["speaker"] as? Int).map { "\(source):speaker-\($0)" } ?? "\(source):unknown"
            if let last = result.last, last.speaker == speaker, start + offset - last.end < 1.5 {
                result[result.count - 1].text += " " + text
                result[result.count - 1].end = end + offset
            } else {
                result.append(Segment(source: source, speaker: speaker, start: start + offset, end: end + offset, text: text))
            }
        }
        if result.isEmpty, let text = event["transcript"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result = [Segment(source: source, speaker: "\(source):unknown", start: fallbackStart,
                              end: (event["audio_processed"] as? Double ?? 0) + offset, text: text)]
        }
        return result
    }
}
