import Foundation

public struct BackgroundSnippet: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var text: String
    public var cosine: Float
    public init(id: String, title: String, text: String, cosine: Float) {
        self.id = id; self.title = title; self.text = text; self.cosine = cosine
    }
}

