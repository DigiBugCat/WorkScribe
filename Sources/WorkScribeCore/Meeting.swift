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
    public var partialIDs: [String: String]?
    /// Preserve the provisional identity when one recognition result becomes final turns.
    public mutating func setPartial(_ text: String, source: String, speaker: String?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if partialIDs == nil { partialIDs = [:] }
        if partialIDs?[source] == nil { partialIDs?[source] = UUID().uuidString }
        partials[source] = text
        if partialSpeakers == nil { partialSpeakers = [:] }
        partialSpeakers?[source] = speaker
    }
    public mutating func finishPartial(_ final: [Segment], source: String) {
        guard !final.isEmpty else { return }
        var final = final
        if !final.isEmpty, let id = partialIDs?[source] { final[0].id = id }
        segments.append(contentsOf: final)
        partials.removeValue(forKey: source)
        partialSpeakers?.removeValue(forKey: source)
        partialIDs?.removeValue(forKey: source)
    }
    public var failure: String?
    // Missing on legacy recordings: treat those names as manually chosen.
    public var titleOrigin: String?
    public var titleFinal: Bool?
    public var recordingTrigger: String?
    public var sourceOffsets: [String: Double]?
    public var recordingSessions: [RecordingSession]?
    public var speakerAssignments: [String: SpeakerAssignment]?
    public var segmentAssignments: [String: SpeakerAssignment]?
    public var speakerSuggestions: [String: VoiceSuggestion]?
    public var voiceRevision: Int?
    // Shorthand notes and the last final pass's missed topics; absent on older recordings.
    public var notes: [Note]?
    public var missedTopics: [MissedTopic]?
    // Screen recording and its moments file (Screen.swift); absent on audio-only and older recordings.
    public var screen: ScreenCaptureInfo?
    /// Nil on legacy meetings. Raw material lives for at most 24 hours after ending.
    public var retention: String?
    public var purgeAt: Date?
    public var vaultPath: String?
    public var document: NoteDocument?
    public var brief: String?
    public var actionItems: [ActionItem]?
    public var attendees: [String]?
    public var transcriptPolishedForEnd: Date?
    /// Old evidence anchors whose words moved during acoustic re-alignment.
    public var transcriptAliases: [String: String]?
    public func resolvedSegmentID(_ id: String) -> String {
        var current = id, seen = Set<String>()
        while let next = transcriptAliases?[current], seen.insert(current).inserted { current = next }
        return current
    }

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
        if let receipt = try RetentionStore(meetings: self).load(meeting.id), receipt.state == "purged" || receipt.state == "purging" { throw StoreError.invalidID }
        let folder = try directory(meeting.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let file = folder.appendingPathComponent("transcript.json")
        try encoder.encode(meeting).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let retention = RetentionStore(meetings: self)
        if var receipt = try retention.load(meeting.id), receipt.state == "finalized" {
            receipt.title = meeting.title
            try retention.save(receipt)
        }
    }
    public func load(_ id: String) throws -> Meeting {
        if let receipt = try RetentionStore(meetings: self).load(id), receipt.state == "purged" || receipt.state == "purging" { return receipt.meeting }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var meeting = try decoder.decode(Meeting.self, from: Data(contentsOf: directory(id).appendingPathComponent("transcript.json")))
        meeting.vaultPath = meeting.vaultPath.map(FileIdentity.path)
        if let path = meeting.document?.path { meeting.document?.path = FileIdentity.path(path) }
        return meeting
    }
    public func list() -> [Meeting] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var all = entries.compactMap { try? load($0.lastPathComponent) }
        for receipt in RetentionStore(meetings: self).list() where !all.contains(where: { $0.id == receipt.id }) { all.append(receipt.meeting) }
        return all.sorted { $0.startedAt > $1.startedAt }
    }
    /// No capture owner survives a process restart. Recover before exposing API/MCP state.
    /// Idempotent; preserve every segment and audio file, and start the normal retention clock.
    public func recoverInterruptedRecordings(now: Date = Date()) throws {
        for var meeting in list() where ["starting", "recording", "finalizing"].contains(meeting.status) {
            let folder = try directory(meeting.id)
            for journal in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where journal.lastPathComponent.hasSuffix(".wav.transcribing.pcm") {
                let name = String(journal.lastPathComponent.dropLast(".transcribing.pcm".count))
                try AudioBacklog.recoverWAV(journal: journal, destination: folder.appendingPathComponent(name))
            }
            meeting.status = "interrupted"
            meeting.endedAt = meeting.endedAt ?? now
            meeting.purgeAt = meeting.purgeAt ?? meeting.endedAt!.addingTimeInterval(86_400)
            meeting.failure = "Recording was interrupted. Your saved audio and transcript are here."
            try save(meeting)
        }
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
    /// Transcript text is authoritative. Word metadata is an alignment aid, never a filter.
    /// Monotone alignment accepts missing metadata and postprocessor spelling changes.
    public static func timedWords(event: [String: Any], offset: Double, fallbackStart: Double) -> [(text: String, start: Double, end: Double, speaker: Int?)] {
        let metadata = (event["words"] as? [[String: Any]] ?? []).flatMap { word -> [[String: Any]] in
            let parts = (word["word"] as? String ?? "").split(whereSeparator: \.isWhitespace)
            return parts.map { part in var copy = word; copy["word"] = String(part); return copy }
        }
        let transcript = (event["transcript"] as? String ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        let text = transcript.isEmpty ? metadata.compactMap { $0["word"] as? String } : transcript
        guard !text.isEmpty else { return [] }
        func key(_ text: String) -> String { String(text.lowercased().filter { $0.isLetter || $0.isNumber }) }
        let keys = metadata.map { key($0["word"] as? String ?? "") }
        var aligned = Array<[String: Any]?>(repeating: nil, count: text.count)
        let textKeys = text.map(key)
        var prefix = 0
        while prefix < min(text.count, metadata.count), textKeys[prefix] == keys[prefix] {
            aligned[prefix] = metadata[prefix]; prefix += 1
        }
        var textEnd = text.count, wordEnd = metadata.count
        while textEnd > prefix, wordEnd > prefix, textKeys[textEnd - 1] == keys[wordEnd - 1] {
            textEnd -= 1; wordEnd -= 1; aligned[textEnd] = metadata[wordEnd]
        }
        let n = textEnd - prefix, m = wordEnd - prefix
        if n > 0, m > 0, n * m <= 1_000_000 {
            // Longest common subsequence prevents a missing repeated word from
            // stealing a later word's timestamp. Most native events take only
            // the identical-prefix fast path above.
            var lcs = [Int32](repeating: 0, count: (n + 1) * (m + 1))
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i * (m + 1) + j] = textKeys[prefix + i] == keys[prefix + j]
                        ? 1 + lcs[(i + 1) * (m + 1) + j + 1]
                        : max(lcs[(i + 1) * (m + 1) + j], lcs[i * (m + 1) + j + 1])
                }
            }
            var i = 0, j = 0
            while i < n && j < m {
                if textKeys[prefix + i] == keys[prefix + j] {
                    aligned[prefix + i] = metadata[prefix + j]; i += 1; j += 1
                } else if lcs[(i + 1) * (m + 1) + j] >= lcs[i * (m + 1) + j + 1] { i += 1 }
                else { j += 1 }
            }
        } else if n > 0, m > 0 {
            // Bounded fallback for malformed, very large remote events.
            var cursor = prefix
            for i in prefix..<textEnd {
                if cursor < wordEnd, let match = (cursor..<min(cursor + 16, wordEnd)).first(where: { keys[$0] == textKeys[i] }) {
                    aligned[i] = metadata[match]; cursor = match + 1
                }
            }
        }
        func time(_ value: Any?) -> Double? {
            guard let v = value as? NSNumber, v.doubleValue.isFinite, v.doubleValue >= 0 else { return nil }
            return v.doubleValue + offset
        }
        let end = max(fallbackStart, time(event["audio_processed"]) ?? fallbackStart)
        var result: [(String, Double, Double, Int?)] = []
        for i in text.indices {
            let previousEnd = result.last?.2 ?? fallbackStart
            let nextIndex = text.indices.dropFirst(i + 1).first { time(aligned[$0]?["start"]) != nil }
            let nextTime = nextIndex.flatMap { time(aligned[$0]?["start"]) } ?? end
            let start = max(previousEnd, time(aligned[i]?["start"]) ?? previousEnd)
            // Share an untimed run's gap instead of giving its entire duration to
            // the first word. Text-only results get usable monotone timing too.
            let remaining = (nextIndex ?? text.count) - i
            let inferredEnd = start + max(0, nextTime - start) / Double(max(1, remaining))
            let finish = max(start, time(aligned[i]?["end"]) ?? inferredEnd)
            let speaker = (aligned[i]?["speaker"] as? Int) ?? result.last?.3 ?? aligned.dropFirst(i + 1).compactMap { $0?["speaker"] as? Int }.first
            result.append((text[i], start, finish, speaker))
        }
        return result
    }
    public static func segments(event: [String: Any], source: String, offset: Double, fallbackStart: Double) -> [Segment] {
        var result: [Segment] = []
        for word in timedWords(event: event, offset: offset, fallbackStart: fallbackStart) {
            let speaker = word.speaker.flatMap { $0 > 0 ? "\(source):speaker-\($0)" : nil } ?? "\(source):unknown"
            if let last = result.last, last.speaker == speaker, word.start - last.end < 1.5,
               word.end - last.start <= 30, last.text.split(whereSeparator: \.isWhitespace).count < 60 {
                result[result.count - 1].text += " " + word.text
                result[result.count - 1].end = word.end
            } else {
                result.append(Segment(source: source, speaker: speaker, start: word.start, end: word.end, text: word.text))
            }
        }
        return result
    }
}
