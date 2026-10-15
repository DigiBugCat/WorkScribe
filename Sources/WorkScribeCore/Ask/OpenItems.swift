import Foundation

/// An action item someone wrote in a meeting's shorthand notes ("TODO send Halvorsen the checklist", "[ ] review
/// merge prototype", "AI: Priya emails by Fri"). Until notes carry structured tasks, these come from note text.
public struct OpenItem: Equatable, Sendable, Identifiable {
    public var id: String { meetingID + "/" + noteID }
    public var text: String
    public var meetingID: String
    public var meetingTitle: String
    public var noteID: String
    /// Seconds into the meeting the note was typed, when known.
    public var at: Double?
    public var meetingStarted: Date
    public var link: WorkScribeLink { .meeting(id: meetingID, seconds: at, segment: nil) }
}

public enum OpenItems {
    /// Markers that make a note line an action item; the marker is removed from the displayed text.
    static let markers: [String] = [
        #"^\s*[-*]?\s*\[\s\]\s*"#,                       // [ ] task, - [ ] task
        #"^\s*(todo|to-do|action item|action|ai|fu|follow[- ]?up)\s*[:\-–]\s*"#,
        #"^\s*(todo|to-do)\s+"#,
        #"^\s*(->|→)\s*"#,
    ]
    /// Completed tasks are never open.
    static let done = #"^\s*[-*]?\s*\[[xX]\]"#

    /// The item text when `line` is an action item, else nil.
    public static func actionText(_ line: String) -> String? {
        if line.range(of: done, options: .regularExpression) != nil { return nil }
        for marker in markers {
            if let range = line.range(of: marker, options: [.regularExpression, .caseInsensitive]) {
                let rest = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                return rest.isEmpty ? nil : rest
            }
        }
        return nil
    }

    /// Open items across meetings, newest meeting first, at most `limit`.
    public static func extract(from meetings: [Meeting], limit: Int = 20) -> [OpenItem] {
        var items: [OpenItem] = []
        for meeting in meetings.sorted(by: { $0.startedAt > $1.startedAt }) {
            for note in meeting.notes ?? [] {
                for line in note.text.split(whereSeparator: \.isNewline) {
                    guard let text = actionText(String(line)) else { continue }
                    items.append(OpenItem(text: text, meetingID: meeting.id, meetingTitle: meeting.title, noteID: note.id,
                                          at: note.createdAt, meetingStarted: meeting.startedAt))
                    if items.count >= limit { return items }
                }
            }
        }
        return items
    }
}

/// People named in meetings: assigned speaker names, with the meetings they spoke in.
public struct PersonSummary: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var meetingIDs: [String]
    public var lastSeen: Date
}

public enum People {
    public static func summarize(_ meetings: [Meeting], remembered: [String] = []) -> [PersonSummary] {
        var byName: [String: PersonSummary] = [:]
        for meeting in meetings {
            var names = Set<String>()
            for segment in meeting.segments { if let name = meeting.assignment(for: segment)?.name { names.insert(name) } }
            for name in names {
                var entry = byName[name] ?? PersonSummary(name: name, meetingIDs: [], lastSeen: .distantPast)
                entry.meetingIDs.append(meeting.id)
                entry.lastSeen = max(entry.lastSeen, meeting.startedAt)
                byName[name] = entry
            }
        }
        for name in remembered where byName[name] == nil {
            byName[name] = PersonSummary(name: name, meetingIDs: [], lastSeen: .distantPast)
        }
        return byName.values.sorted { $0.lastSeen != $1.lastSeen ? $0.lastSeen > $1.lastSeen : $0.name < $1.name }
    }
}
