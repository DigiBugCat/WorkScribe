import Foundation

/// The app and replay use this exact handoff. Pressure throttles presentation only:
/// the newest hypothesis and every completed event are always consumed.
public struct LiveTranscript {
    private var latest: [String: [String: Any]] = [:]
    private var displayed: [String: Date] = [:]
    private var ends: [String: Double] = [:]
    public private(set) var hiddenPartials = 0
    public var unfinishedSources: [String] { Array(latest.keys).sorted() }
    public init() {}
    @discardableResult public mutating func consume(_ event: [String: Any], source: String, offset: Double,
                                                    pressure: RecordingPressure, meeting: inout Meeting,
                                                    now: Date = Date()) -> Bool {
        let kind = event["type"] as? String ?? ""
        if kind.hasSuffix(".partial") {
            if !(event["transcript"] as? String ?? "").isEmpty { latest[source] = event }
            if pressure == .transcriptDelayed && now.timeIntervalSince(displayed[source] ?? .distantPast) < 3 {
                hiddenPartials += 1; return false
            }
            displayed[source] = now
            if let text = event["transcript"] as? String, !text.isEmpty {
                meeting.setPartial(text, source: source, speaker: TranscriptParser.partialSpeaker(event: event, source: source))
            }
        } else if kind.hasSuffix(".completed") {
            var final = event
            if (event["transcript"] as? String ?? "").isEmpty, (event["words"] as? [[String: Any]] ?? []).isEmpty,
               let hypothesis = latest[source] { final = hypothesis }
            let segments = TranscriptParser.segments(event: final, source: source, offset: offset, fallbackStart: ends[source] ?? offset)
            guard !segments.isEmpty else { return false }
            meeting.finishPartial(segments, source: source)
            ends[source] = segments.last?.end
            latest.removeValue(forKey: source)
        } else { return false }
        return true
    }
}
