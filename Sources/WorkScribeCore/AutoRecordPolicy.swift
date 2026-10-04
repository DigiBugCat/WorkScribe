import Foundation

/// Pure policy: a detected call must settle before starting; temporary mute
/// gaps do not split a recording. A manual stop suppresses the current call.
public struct AutoRecordPolicy {
    public enum Action: Equatable { case none, start, stop }
    public var settleSeconds: TimeInterval = 3
    public var endGraceSeconds: TimeInterval = 120
    private var candidateSince: Date?
    private var absentSince: Date?
    private var suppressed = false
    private var requestedStart = false
    public init() {}
    public mutating func suppressCurrentCall() {
        suppressed = true; candidateSince = nil; absentSince = nil; requestedStart = false
    }
    public mutating func reset() {
        candidateSince = nil; absentSince = nil; requestedStart = false; suppressed = false
    }
    public mutating func update(callActive: Bool, enabled: Bool, busy: Bool, automaticallyRecording: Bool, now: Date) -> Action {
        guard enabled else { reset(); return .none }
        if callActive {
            absentSince = nil
            guard !suppressed else { return .none }
            if candidateSince == nil { candidateSince = now }
            guard !busy, !requestedStart, now.timeIntervalSince(candidateSince!) >= settleSeconds else { return .none }
            requestedStart = true
            return .start
        }
        candidateSince = nil
        if absentSince == nil { absentSince = now }
        guard now.timeIntervalSince(absentSince!) >= endGraceSeconds else { return .none }
        suppressed = false; requestedStart = false
        return automaticallyRecording ? .stop : .none
    }
}

public enum CallApplicationPolicy {
    public static func nativeName(bundleID: String) -> String? {
        let known = ["us.zoom.xos": "Zoom", "com.microsoft.teams2": "Microsoft Teams",
                     "com.microsoft.teams": "Microsoft Teams", "com.cisco.webexmeetingsapp": "Webex",
                     "com.cisco.webex": "Webex", "com.apple.FaceTime": "FaceTime",
                     "com.tinyspeck.slackmacgap": "Slack", "com.hnc.Discord": "Discord"]
        return known.first { bundleID == $0.key || bundleID.hasPrefix($0.key + ".") }?.value
    }
    public static func browserName(bundleID: String) -> String? {
        let known = ["com.google.Chrome": "Chrome", "com.apple.Safari": "Safari",
                     "com.microsoft.edgemac": "Edge", "org.mozilla.firefox": "Firefox",
                     "com.brave.Browser": "Brave", "company.thebrowser.Browser": "Arc"]
        return known.first { bundleID == $0.key || bundleID.hasPrefix($0.key + ".") }?.value
    }
    public static func isMeetingWindow(_ title: String) -> Bool {
        let value = title.lowercased()
        return value.contains("google meet") || value.hasPrefix("meet - ") || value.contains("microsoft teams")
            || value.contains("zoom meeting") || value.contains("zoom workplace") || value.contains("webex")
            || value.contains("slack huddle") || value.contains("huddle | slack")
    }
}
