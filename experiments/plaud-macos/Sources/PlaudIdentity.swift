import Foundation

/// The device is bound to the Plaud user created from this ID. Signing in from
/// WorkScribe must reuse the lab's ID; a fresh one would be a different owner.
struct PlaudIdentity {
    static let labDomain = "local.workscribe.plaud-lab"
    static let key = "plaud.native.userID"
    let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: Self.labDomain) ?? .standard
    }
    var existing: String? { defaults.string(forKey: Self.key) }
    func userID() -> String {
        if let existing { return existing }
        let created = "workscribe-" + UUID().uuidString
        defaults.set(created, forKey: Self.key)
        return created
    }
}

/// One recording saved from the recorder and decoded on this Mac.
public struct PlaudSavedRecording: Identifiable, Equatable, Sendable {
    public let id: String
    public let audioURL: URL
    public let recordedAt: Date?
    public init(id: String, audioURL: URL, recordedAt: Date?) {
        self.id = id; self.audioURL = audioURL; self.recordedAt = recordedAt
    }

    /// Recorder session IDs are Unix start times. Anything outside a plausible
    /// window is treated as unknown rather than shown as a wrong date.
    static func recordedAt(sessionID: Int, now: Date = Date()) -> Date? {
        let date = Date(timeIntervalSince1970: TimeInterval(sessionID))
        let earliest = Date(timeIntervalSince1970: 1_514_764_800) // 2018-01-01
        return date >= earliest && date <= now.addingTimeInterval(86_400) ? date : nil
    }
}
