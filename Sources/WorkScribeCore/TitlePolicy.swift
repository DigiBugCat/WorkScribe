import Foundation

public enum TitlePolicy {
    public static func canGenerate(_ meeting: Meeting, final: Bool) -> Bool {
        guard meeting.titleOrigin == "pending" || meeting.titleOrigin == "automatic" else { return false }
        if meeting.titleFinal == true { return false }
        if !final && meeting.titleOrigin == "automatic" { return false }
        let words = meeting.segments.map(\.text).joined(separator: " ").split(whereSeparator: \.isWhitespace).count
        return words >= (final ? 6 : 45)
    }
    public static func excerpt(_ meeting: Meeting) -> String {
        let words = meeting.orderedSegments.map(\.text).joined(separator: " ").split(whereSeparator: \.isWhitespace)
        let selected: [Substring]
        if words.count <= 420 { selected = Array(words) }
        else {
            let middle = max(0, words.count / 2 - 70)
            selected = Array(words.prefix(140)) + Array(words[middle..<(middle + 140)]) + Array(words.suffix(140))
        }
        // The transcript is data, and cannot introduce chat-template delimiters.
        return String(selected.joined(separator: " ").prefix(5200))
            .replacingOccurrences(of: "<", with: "(").replacingOccurrences(of: ">", with: ")")
    }
    public static func clean(_ output: String) -> String? {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.components(separatedBy: .newlines).first ?? ""
        if text.lowercased().hasPrefix("title:") { text = String(text.dropFirst(6)) }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'`*#.:“”"))
        let words = text.split(whereSeparator: \.isWhitespace)
        guard (2...12).contains(words.count), text.count <= 90,
              !["here is", "here's", "i cannot", "i can't", "no transcript", "not enough", "untitled", "as an ai"].contains(where: { text.lowercased().contains($0) }) else { return nil }
        return words.joined(separator: " ")
    }
}
