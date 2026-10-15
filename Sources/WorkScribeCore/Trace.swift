import Foundation

/// Observable provenance, never private model reasoning. Lives only with raw meeting data.
public struct TraceStep: Codable, Equatable, Sendable {
    public var title: String
    public var status: String
    public var detail: String?
    public init(_ title: String, status: String = "complete", detail: String? = nil) {
        self.title = title; self.status = status; self.detail = detail
    }
}
public struct TraceRevision: Codable, Equatable, Sendable {
    public var version: Int
    public var text: String
    public var reason: String
    public var at: Date
    public init(version: Int, text: String, reason: String, at: Date) {
        self.version = version; self.text = text; self.reason = reason; self.at = at
    }
}
public struct TraceSource: Codable, Equatable, Sendable {
    public var kind: String
    public var title: String
    public var text: String
    public var link: String
    public var thumbnail: String?
    public var start: Double?
    public var end: Double?
    public init(kind: String, title: String, text: String, link: String, thumbnail: String? = nil, start: Double? = nil, end: Double? = nil) {
        self.kind = kind; self.title = title; self.text = text; self.link = link; self.thumbnail = thumbnail; self.start = start; self.end = end
    }
}
public struct AITrace: Codable, Equatable, Sendable {
    public var steps: [TraceStep] = []
    public var sources: [TraceSource]?
    public var model: String?
    public var location: String?
    public var durationMs: Int?
    public var revisions: [TraceRevision] = []
    public init() {}
}
