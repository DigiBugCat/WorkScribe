import Foundation

/// Reads caption blocks out of OCR'd lines, for platforms that draw captions without exposing them to
/// Accessibility (Zoom's floating caption box while you share your screen).
///
/// Each block is a speaker's name in a smaller font above the lines they said. When a new block starts,
/// older text scrolls up and is cut off at the top, so the first paragraph can arrive without its name or
/// its opening words; that look is marked `continued`.
public enum CaptionLayout {
    /// Lines in Vision's normalized coordinates (origin at the bottom left).
    public static func looks(from lines: [ScreenTextLine], chrome: Set<String> = []) -> [CaptionStream.Look] {
        let rows = lines
            .filter { !chrome.contains($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .sorted { $0.y + $0.height > $1.y + $1.height }
        let threshold = nameHeight(rows.map(\.height))
        var looks: [CaptionStream.Look] = []
        var speaker: String?, text: [String] = [], continued = true
        func close() {
            if !text.isEmpty { looks.append(.init(speaker: speaker, text: text.joined(separator: " "), continued: continued)) }
            text = []
        }
        for row in rows {
            let value = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let threshold, row.height <= threshold, value.count <= 60, value.split(separator: " ").count <= 6 {
                close(); speaker = value; continued = false
            } else {
                text.append(value)
            }
        }
        close()
        return looks
    }

    /// Names are set noticeably smaller than caption text: the cut between the two sizes, or nil when
    /// every line is the same size.
    static func nameHeight(_ heights: [Double]) -> Double? {
        let sorted = heights.sorted()
        guard sorted.count >= 2 else { return nil }
        var best = 0, ratio = 1.0
        for i in 0..<(sorted.count - 1) where sorted[i] > 0 && sorted[i + 1] / sorted[i] > ratio {
            ratio = sorted[i + 1] / sorted[i]; best = i
        }
        return ratio >= 1.15 ? (sorted[best] + sorted[best + 1]) / 2 : nil
    }
}
