import Foundation
import WorkScribeCore

/// Pinned E4B evaluation using the production resident llama.cpp model.
enum GemmaEvaluation {
    static let modelID = "gemma4-e4b"
    static let template = (head: "<bos><|turn>user\n", tail: "<turn|>\n<|turn>model\n")
    static let ggufRevision = "b8093469224f83f5c38f691eb906c380e9e63114"
    static let ggufSHA256 = "a555b900214b477d8880e7832e0b8925e139b0159640036b09fe472b6f2097f2"

    static func model(runtime: String) throws -> ResidentTextModel {
        guard runtime == "llama" else { throw CaptureError.message("Only the llama runtime is supported") }
        let path = ProcessInfo.processInfo.environment["WORKSCRIBE_TEXT_MODEL"] ?? RuntimeAssets.model(GeneratorModel.gemma4.filename).path
        try RuntimeAssets.require(URL(fileURLWithPath: path))
        return TextModels.generator(.gemma4, path: path)
    }
}
