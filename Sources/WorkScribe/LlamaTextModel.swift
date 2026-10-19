import Foundation
import CTextGeneration
import WorkScribeCore

/// The llama.cpp backend: one resident `ws_text_session` (model + context) for a GGUF. The KV and
/// recurrent memory is cleared between calls; each prompt family's fixed instruction prefix is
/// saved once with `llama_state_seq_get_data` and restored with `llama_state_seq_set_data`, which is
/// exact, so the text is byte-identical to prefilling the whole prompt (`TextModelTests`).
final class LlamaTextEngine: TextEngine {
    // engine.md §4: a 1.5k line prompt (3k Ask) fits 4096; micro-batches bound scratch memory.
    static let batchSize: Int32 = 512
    static let contextSize: Int32 = 4096
    let model: GeneratorModel
    let path: String
    private var session: OpaquePointer?

    init(model: GeneratorModel, path: String) { self.model = model; self.path = path }

    static func resident(model: GeneratorModel, path: String) -> ResidentTextModel {
        ResidentTextModel(displayName: "\(model.displayName) · \(TextBackend.llama.rawValue)", backend: .llama,
                          engine: LlamaTextEngine(model: model, path: path),
                          available: { RuntimeAssets.inspect(URL(fileURLWithPath: path)) == .present })
    }

    /// The model's chat template around one user turn; thinking off.
    static func template(_ model: GeneratorModel) -> (head: String, tail: String) {
        ("<|turn>user\n", "<turn|>\n<|turn>model\n")
    }

    var isLoaded: Bool { session != nil }

    func load() throws {
        try RuntimeAssets.require(URL(fileURLWithPath: path))
        var error = [CChar](repeating: 0, count: 512)
        guard let opened = ws_session_open(path, Self.contextSize, Self.batchSize, &error, error.count) else {
            throw CaptureError.message(String(cString: error))
        }
        session = opened
    }

    func generate(_ request: TextRequest, control: GenerationControl) throws -> TextGeneration {
        guard let session else { throw CaptureError.message("The text model is not loaded") }
        let template = Self.template(model)
        let prompt = template.head + request.instruction + template.tail
        let prefixBytes = request.cacheablePrefix.map { (template.head + $0).utf8.count } ?? 0
        var output = [CChar](repeating: 0, count: 64 * 1024)
        var error = [CChar](repeating: 0, count: 512)
        var stats = ws_generation_stats()
        let context = Unmanaged.passRetained(control).toOpaque()
        defer { Unmanaged<GenerationControl>.fromOpaque(context).release() }
        let status = ws_session_generate(session, prompt, prefixBytes, Int32(request.maxTokens), request.stop, request.firstLine ? 1 : 0,
                                         control.onPiece == nil ? nil : Self.onPiece, Self.shouldCancel,
                                         context, &output, output.count, &stats, &error, error.count)
        if status == 2 { throw CancellationError() }
        if status != 0 { throw CaptureError.message(String(cString: error)) }
        return TextGeneration(text: String(cString: output), stats: TextStats(
            promptTokens: Int(stats.prompt_tokens), reusedTokens: Int(stats.reused_tokens), generatedTokens: Int(stats.generated_tokens),
            prefixBuilt: stats.prefix_built != 0, prefillMs: stats.prefill_ms, ttftMs: stats.ttft_ms, totalMs: stats.total_ms))
    }

    struct DecisionScores {
        var logProbabilities: [Double]
        var stats: TextStats
        var prefixCacheBytes: Int
    }
    /// One prefill per row, no output decoding; rows share the resident instruction-prefix cache.
    /// Alternative tokenization is validated by C before scoring any row.
    func scoreOptions(_ requests: [TextRequest], options: [String] = ["A", "B"],
                      control: GenerationControl = GenerationControl()) throws -> [DecisionScores] {
        guard let session else { throw CaptureError.message("The text model is not loaded") }
        guard !requests.isEmpty else { return [] }
        let template = Self.template(model)
        let prompts = requests.map { strdup(template.head + $0.instruction + template.tail)! }
        let choices = options.map { strdup($0)! }
        defer { prompts.forEach { free($0) }; choices.forEach { free($0) } }
        var pointers = prompts.map { Optional(UnsafePointer($0)) }
        var alternatives = choices.map { Optional(UnsafePointer($0)) }
        var prefix = requests.map { $0.cacheablePrefix.map { (template.head + $0).utf8.count } ?? 0 }
        var values = [Double](repeating: 0, count: requests.count * options.count)
        var stats = [ws_generation_stats](repeating: ws_generation_stats(), count: requests.count)
        var error = [CChar](repeating: 0, count: 512)
        let context = Unmanaged.passRetained(control).toOpaque()
        defer { Unmanaged<GenerationControl>.fromOpaque(context).release() }
        let status = ws_session_score_options(session, &pointers, &prefix, Int32(requests.count),
                                               &alternatives, Int32(options.count), &values, &stats,
                                               Self.shouldCancel, context, &error, error.count)
        if status == 2 { throw CancellationError() }
        guard status == 0 else { throw CaptureError.message(String(cString: error)) }
        return stats.enumerated().map { index, stat in
            DecisionScores(logProbabilities: Array(values[(index * options.count)..<((index + 1) * options.count)]),
                           stats: TextStats(promptTokens: Int(stat.prompt_tokens), reusedTokens: Int(stat.reused_tokens),
                                            generatedTokens: 0, prefixBuilt: stat.prefix_built != 0,
                                            prefillMs: stat.prefill_ms, totalMs: stat.total_ms),
                           prefixCacheBytes: Int(stat.prefix_cache_bytes))
        }
    }

    private static let onPiece: ws_piece_callback = { piece, context in
        guard let piece, let context else { return 1 }
        let control = Unmanaged<GenerationControl>.fromOpaque(context).takeUnretainedValue()
        return control.onPiece?(String(cString: piece)) == false ? 1 : 0
    }
    private static let shouldCancel: ws_cancel_callback = { context in
        guard let context else { return 0 }
        return Unmanaged<GenerationControl>.fromOpaque(context).takeUnretainedValue().isCancelled ? 1 : 0
    }

    func dropCaches() { if let session { ws_session_clear_prefixes(session) } }

    func unload() {
        if let session { ws_session_close(session) }
        session = nil
    }
}
