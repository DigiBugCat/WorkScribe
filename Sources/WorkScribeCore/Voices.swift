import Foundation

public struct SpeakerAssignment: Codable, Equatable {
    public var name: String
    public var profileID: String?
    public var remember: Bool
    public init(name: String, profileID: String? = nil, remember: Bool = false) {
        self.name = name; self.profileID = profileID; self.remember = remember
    }
    // An empty override explicitly restores a segment's original label.
    public static let original = SpeakerAssignment(name: "")
}

public struct VoiceSuggestion: Codable, Equatable {
    public var profileID: String
    public var name: String
    public var similarity: Float
    public init(profileID: String, name: String, similarity: Float) {
        self.profileID = profileID; self.name = name; self.similarity = similarity
    }
}

public struct VoiceSample: Codable, Equatable {
    public var meetingID: String
    public var segmentID: String
    public var vector: [Float]
    public var modelVersion: String?
    public init(meetingID: String, segmentID: String, vector: [Float]) {
        self.meetingID = meetingID; self.segmentID = segmentID; self.vector = vector; self.modelVersion = VoiceMatching.modelVersion
    }
}

public struct VoiceProfile: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var samples: [VoiceSample]
    public init(name: String) { id = UUID().uuidString; self.name = name; samples = [] }
}

public struct VoiceStore {
    public let url: URL
    public init(root: URL) { url = root.appendingPathComponent("voices.json") }
    public func load() throws -> [VoiceProfile] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([VoiceProfile].self, from: Data(contentsOf: url))
    }
    public func save(_ profiles: [VoiceProfile]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(profiles).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum VoiceMatching {
    public static let modelVersion = "fluidaudio-wespeaker-v2-256"
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count, a.allSatisfy(\.isFinite), b.allSatisfy(\.isFinite) else { return -1 }
        let aa = a.reduce(Float(0)) { $0 + $1 * $1 }, bb = b.reduce(Float(0)) { $0 + $1 * $1 }
        guard aa > 0, bb > 0 else { return -1 }
        return zip(a,b).reduce(Float(0)) { $0 + $1.0 * $1.1 } / sqrt(aa * bb)
    }
    /// Suggestions only. Scores are cosine similarities, never probabilities.
    /// Require agreement from each available query and separation from runner-up.
    public static func suggest(vectors: [[Float]], profiles: [VoiceProfile], excluding meetingID: String) -> VoiceSuggestion? {
        guard !vectors.isEmpty else { return nil }
        let scores: [(VoiceProfile, Float)] = profiles.compactMap { profile in
            let samples = profile.samples.filter { $0.meetingID != meetingID && $0.modelVersion == modelVersion }
            guard !samples.isEmpty else { return nil }
            let score = vectors.map { vector in samples.map { cosine(vector, $0.vector) }.max() ?? -1 }.min() ?? -1
            return (profile, score)
        }.sorted { $0.1 > $1.1 }
        guard let best = scores.first, best.1 >= 0.65,
              scores.count == 1 || best.1 - scores[1].1 >= 0.12 else { return nil }
        return VoiceSuggestion(profileID: best.0.id, name: best.0.name, similarity: best.1)
    }
    /// Avoid mixed/overlapping chunks and require three seconds of one speaker.
    public static func eligible(_ segment: Segment, in meeting: Meeting) -> Bool {
        guard meeting.sourceOffsets?[segment.source] != nil,
              segment.end - segment.start >= 3,
              segment.speaker.contains(":speaker-"), !segment.speaker.hasSuffix("-0") else { return false }
        return !meeting.segments.contains { other in
            other.id != segment.id && other.source == segment.source && other.speaker != segment.speaker
                && other.start < segment.end && other.end > segment.start
        }
    }
}
