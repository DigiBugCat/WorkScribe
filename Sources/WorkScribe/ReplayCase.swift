import Foundation
import WorkScribeCore

/// Input only. Gold and rubric fields are intentionally absent from this type.
struct ReplayCase: Codable {
    struct Speech: Codable {
        var id: String; var speaker: String; var start: Double; var end: Double; var text: String
        var final_at: Double?
        var finalizedAt: Double { final_at ?? end + 0.5 }
    }
    struct Edit: Codable { var at: Double; var text: String }
    struct Jot: Codable { var id: String; var text: String; var at: Double; var edits: [Edit]? }
    struct Retraction: Codable { var at: Double; var segments: [String] }
    struct Vault: Codable { var id: String; var title: String; var markdown: String }
    var id: String; var title: String?; var status: String
    var speech: [Speech]; var jots: [Jot]; var stop_at: Double
    var retractions: [Retraction]?; var vault: [Vault]?
    var audio: String?

    func validate() throws {
        let times = speech.flatMap { [$0.start, $0.end, $0.finalizedAt] } + jots.flatMap { [$0.at] + ($0.edits ?? []).map(\.at) } + (retractions ?? []).map(\.at) + [stop_at]
        let ids = Set(speech.map(\.id))
        guard id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil, Set(jots.map(\.id)).count == jots.count, ids.count == speech.count,
              times.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= stop_at }),
              speech.allSatisfy({ $0.start <= $0.end && $0.end <= $0.finalizedAt }),
              jots.allSatisfy({ jot in (jot.edits ?? []).allSatisfy { $0.at >= jot.at } }),
              (retractions ?? []).allSatisfy({ Set($0.segments).isSubset(of: ids) }),
              Set((vault ?? []).map(\.id)).count == (vault ?? []).count else {
            throw CaptureError.message("Invalid replay identities or timestamps: \(id)")
        }
    }
    func meeting() -> Meeting {
        var value = Meeting(title: title ?? id)
        value.id = id; value.startedAt = Date(timeIntervalSince1970: 0); value.status = "recording"
        value.notes = []; value.segments = []; value.speakerAssignments = [:]
        for (index, speaker) in Array(Set(speech.map(\.speaker))).sorted().enumerated() {
            if speaker.range(of: #"(?i)^speaker[ -]*\d+$"#, options: .regularExpression) == nil {
                value.speakerAssignments?["replay:speaker-\(index + 1)"] = SpeakerAssignment(name: speaker)
            }
        }
        return value
    }
    func segment(_ speech: Speech) -> Segment {
        let speakers = Array(Set(self.speech.map(\.speaker))).sorted()
        let key = "replay:speaker-\((speakers.firstIndex(of: speech.speaker) ?? 0) + 1)"
        var value = Segment(source: "replay", speaker: key, start: speech.start, end: speech.end, text: speech.text)
        value.id = speech.id
        return value
    }
}
