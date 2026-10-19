import Foundation

/// Constants are shared by the product and replay. Only replay decodes alternative arms.
public struct EngineConstants: Codable, Equatable, Sendable {
    // engine.md §2.7: one 8–45-word line and 96 generated tokens.
    public static let lineWords = 45
    public static let lineMinimumWords = 8
    /// Shortest line allowed when it carries a concrete fact (a direct answer such as "Team is $20").
    public static let lineShortWords = 3
    public static let lineTokens = 96
    // §4 reserves ten calls beyond the line budget; optional synthesis must fit inside it.
    public static let synthesisCalls = 10
    // 4096 context leaves room for the 500-token synthesis output and chat delimiters.
    public static let synthesisPromptTokens = 3000
    public static let chunkWords = 60
    public static let chunkTailWords = 15
    // engine.md §0: 74/82 answerable jots have gold in this window.
    public var lookback = 90.0
    public var lookahead = 30.0
    // Stage 3b: retain weak evidence; competing open jots and the prompt budget bound it.
    public var keep = 0.0
    public var stop = 0.5
    // A competing open jot must be decisively more relevant before it can claim a passage.
    public var ownershipMargin = 0.35
    public var answerable = 0.5
    // Vault branch floor; not calibrated on timed meeting pairs.
    public var untimed = 0.78
    // The 1.5k hybrid sweep, engine.md §2.6.
    public var neighbor = 5.0
    public var answerContext = 12.0
    public var promptTokens = 1500
    public var topicGap = false
    public var gateAnswerability = true
    public var backgroundAlways = false
    public init() {}
    public static func load(_ url: URL) throws -> Self {
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self())) as! [String: Any]
        let overrides = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        guard overrides.keys.allSatisfy({ defaults[$0] != nil }) else { throw EmbeddingDecisionModel.Failure.invalidThreshold }
        let value = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: defaults.merging(overrides) { _, new in new }))
        guard [value.keep, value.stop, value.answerable, value.untimed].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              value.keep <= value.stop, [value.lookback, value.lookahead, value.neighbor, value.answerContext].allSatisfy({ $0.isFinite && $0 >= 0 }), value.promptTokens > 0 else { throw EmbeddingDecisionModel.Failure.invalidThreshold }
        return value
    }
}

