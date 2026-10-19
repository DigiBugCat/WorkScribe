import Foundation

/// Each capture owns a fresh speaker namespace. Times remain on the original meeting clock.
public struct RecordingSession: Codable, Equatable, Sendable {
    public var id: String
    public var start: Double
    public var end: Double?
    public var sourceOffsets: [String: Double]
    public var screen: ScreenCaptureInfo?
    public var prefix: String { id == "initial" ? "" : "recordings/\(id)/" }
    /// Legacy recording/import lookup only. Live capture never creates these files.
    public func audioFile(_ source: String) -> String { prefix + source + ".wav" }
    public var videoFile: String { prefix + "screen.mov" }
    public init(id: String = UUID().uuidString, start: Double, end: Double? = nil,
                sourceOffsets: [String: Double] = [:], screen: ScreenCaptureInfo? = nil) {
        self.id = id; self.start = start; self.end = end; self.sourceOffsets = sourceOffsets; self.screen = screen
    }
}

extension Meeting {
    public func canResume(at now: Date = Date()) -> Bool {
        guard let endedAt, now >= endedAt, now.timeIntervalSince(endedAt) < 600,
              retention != "purged", retention != "purging", document?.finalized != true else { return false }
        return status == "complete" || status == "interrupted"
    }
    /// Validated before any file or UI state changes. Preserves the note, prior evidence, and speaker assignments.
    public mutating func resume(at now: Date = Date()) throws {
        guard canResume(at: now) else { throw ResumeError.unavailable }
        if recordingSessions == nil {
            recordingSessions = [RecordingSession(id: "initial", start: 0,
                end: endedAt!.timeIntervalSince(startedAt), sourceOffsets: sourceOffsets ?? [:], screen: screen)]
        }
        recordingSessions!.append(RecordingSession(start: now.timeIntervalSince(startedAt)))
        endedAt = nil; purgeAt = nil; retention = "live"; status = "recording"; failure = nil
        partials = [:]; partialSpeakers = [:]; partialIDs = [:]
        for i in (notes ?? []).indices { notes![i].line.resume() }
    }
    public enum ResumeError: Error { case unavailable }
    public func audioLocation(for segment: Segment) -> (file: String, offset: Double)? {
        if let sessions = recordingSessions,
           let session = sessions.last(where: { segment.start >= $0.start && ($0.end == nil || segment.start <= $0.end!) }),
           let offset = session.sourceOffsets[segment.source] {
            return (session.audioFile(segment.source), offset)
        }
        if recordingSessions != nil { return nil }
        return sourceOffsets?[segment.source].map { (segment.source + ".wav", $0) }
    }
}
