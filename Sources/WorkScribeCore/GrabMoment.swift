import Foundation

/// The API returns pixels; Obsidian owns attachment placement and the undoable editor insertion.
public struct GrabMoment: Codable, Equatable, Sendable {
    public var filename: String
    public var png: String
    public var at: Double
    public init(data: Data, at: Double, date: Date = Date()) {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"; formatter.timeZone = .current
        filename = "Meeting screen " + formatter.string(from: date) + " " + UUID().uuidString.prefix(6) + ".png"
        png = data.base64EncodedString(); self.at = at
    }
}
