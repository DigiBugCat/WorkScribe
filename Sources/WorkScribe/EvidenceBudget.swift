import Foundation
import WorkScribeCore
import CTextGeneration

/// Tokenizer metadata only; no generator or inference context is created.
final class E4BVocabulary: @unchecked Sendable {
    private let value: OpaquePointer
    private let lock = NSLock()
    private let cacheLimit: Int
    private var counts: [Data: Int] = [:]
    init(path: String, cacheLimit: Int = 512) throws {
        var error = [CChar](repeating: 0, count: 512)
        guard let loaded = ws_vocabulary_open(path, &error, error.count) else { throw CaptureError.message(String(cString: error)) }
        value = loaded
        self.cacheLimit = cacheLimit
    }
    deinit { ws_vocabulary_close(value) }
    func count(_ text: String) -> Int {
        lock.withLock {
            let key = Data(text.utf8)
            if let cached = counts[key] { return cached }
            let count = Int(ws_vocabulary_count(value, text))
            precondition(count >= 0, "E4B vocabulary tokenization failed")
            if counts.count >= cacheLimit { counts.removeAll(keepingCapacity: true) }
            counts[key] = count
            return count
        }
    }
}

enum EvidenceBudget {
    private static let vocabulary = Result { try E4BVocabulary(path: ProcessInfo.processInfo.environment["WORKSCRIBE_TEXT_MODEL"] ?? RuntimeAssets.model(GeneratorModel.gemma4.filename).path) }
    static func synthesisFits(_ prompt: String) throws -> Bool {
        let template = LlamaTextEngine.template(.gemma4)
        return try vocabulary.get().count("<bos>" + template.head + prompt + template.tail) <= EngineConstants.synthesisPromptTokens
    }
    static func apply(_ batch: inout EnrichmentBatch, constants: EngineConstants, count: ((String) -> Int)? = nil) throws {
        let count = try count ?? vocabulary.get().count
        let template = LlamaTextEngine.template(.gemma4)
        let correction = LineRejection.allCases.filter { $0.correction != nil }.max {
            count("<correction>" + $0.correction! + "</correction>\n") < count("<correction>" + $1.correction! + "</correction>\n")
        }
        try batch.limitPromptTokens(constants.promptTokens) { target, evidence in
            count("<bos>" + template.head + LinePrompt.build(target, excerpts: evidence, background: target.background, correction: correction) + template.tail)
        }
    }
}
