import Foundation
import WorkScribeCore

/// Keeps what is sent for one line, or one synthesis call, bounded.
enum EvidenceBudget {
    static func synthesisFits(_ prompt: String) -> Bool {
        PromptSize.tokens(prompt) <= EngineConstants.synthesisPromptTokens
    }
    static func apply(_ batch: inout EnrichmentBatch, constants: EngineConstants, count: ((String) -> Int)? = nil) throws {
        let count = count ?? PromptSize.tokens
        // Leave room for the longest correction a retry may add.
        let correction = LineRejection.allCases.filter { $0.correction != nil }.max {
            count("<correction>" + $0.correction! + "</correction>\n") < count("<correction>" + $1.correction! + "</correction>\n")
        }
        try batch.limitPromptTokens(constants.promptTokens) { target, evidence in
            count(LinePrompt.build(target, excerpts: evidence, background: target.background, correction: correction))
        }
    }
}
