import Foundation

/// A waiting, unanswerable jot must not repeatedly take priority from updates.
public struct FirstLinePriority {
    private var received: [String: Int] = [:]
    public init() {}
    public mutating func receive(_ notes: [Note]) -> Bool {
        received = received.filter { id, _ in notes.contains { $0.id == id } }
        var first = false
        for note in notes {
            if received[note.id] != note.queryRevision && note.line.text == nil && note.line.state != .yours {
                first = true
            }
            received[note.id] = note.queryRevision
        }
        return first
    }
}
