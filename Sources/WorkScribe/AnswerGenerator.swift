import Foundation
import CTextGeneration
import WorkScribeCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Writes a short cited answer from an `AskPrompt`, streaming text deltas. The bundled llama.cpp model is the default;
/// Apple's on-device Foundation Models is the other implementation. Add more by conforming and returning them from
/// `AnswerGenerators.preferred()`.
protocol AnswerGenerator: Sendable {
    /// "Qwen 3.5 · on this Mac": shown under answers and in the composer footer.
    var displayName: String { get }
    /// "openai", "local" (for /v1/status).
    var provider: String { get }
    /// The model's name ("gpt-5.4-mini", "Qwen 3.5").
    var modelName: String { get }
    var isAvailable: Bool { get }
    func stream(_ prompt: AskPrompt) -> AsyncThrowingStream<String, Error>
    func stream(_ prompt: AskPrompt, provenance: AnswerProvenance) -> AsyncThrowingStream<String, Error>
}
/// Per-request metadata, so parallel questions cannot borrow each other's fallback identity.
final class AnswerProvenance: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (String, String, String?) = ("", "", nil)
    func set(model: String, provider: String, fallback: String? = nil) {
        lock.lock(); defer { lock.unlock() }; value = (model, provider, fallback)
    }
    func snapshot() -> (model: String, provider: String, fallback: String?) {
        lock.lock(); defer { lock.unlock() }; return value
    }
}
extension AnswerGenerator {
    func stream(_ prompt: AskPrompt, provenance: AnswerProvenance) -> AsyncThrowingStream<String, Error> {
        provenance.set(model: displayName, provider: provider)
        return stream(prompt)
    }
}

enum AnswerGenerators {
    /// The cloud model when "Use cloud models" is on and an OpenAI key is in the Keychain, falling back to the
    /// on-device one (offline, or an API error before any text); otherwise on-device only.
    static func preferred() -> (any AnswerGenerator)? {
        let local = onDevice()
        if CloudSettings.useCloud, let key = CloudSettings.apiKey() {
            let cloud = OpenAIResponsesGenerator(credential: StoredAPIKey(key: key), model: CloudSettings.model)
            return local.map { FallbackAnswerGenerator(primary: cloud, fallback: $0) } ?? cloud
        }
        return local
    }

    /// `answerEngine` default: "auto" (bundled model, else Apple Intelligence), "bundled", "apple", or "none".
    static func onDevice(setting: String = UserDefaults.standard.string(forKey: "answerEngine") ?? "auto") -> (any AnswerGenerator)? {
        let bundled = LlamaAnswerGenerator()
        let apple = appleIntelligence()
        switch setting {
        case "none": return nil
        case "bundled": return bundled.isAvailable ? bundled : nil
        case "apple": return apple?.isAvailable == true ? apple : nil
        default:
            if bundled.isAvailable { return bundled }
            if let apple, apple.isAvailable { return apple }
            return nil
        }
    }

    static func appleIntelligence() -> (any AnswerGenerator)? {
        #if canImport(FoundationModels)
        return AppleIntelligenceAnswerGenerator()
        #else
        return nil
        #endif
    }
}

/// The bundled title model (Qwen 3.5 2B or Gemma 4) through CTextGeneration, loaded per answer and released after,
/// like titles and note enhancement. `WORKSCRIBE_TEXT_MODEL` points at a GGUF for runs outside the app bundle.
final class LlamaAnswerGenerator: AnswerGenerator, @unchecked Sendable {
    private static let queue = DispatchQueue(label: "WorkScribe.ask", qos: .userInitiated)
    let model: TitleModel
    let path: String

    init(model: TitleModel = .bundled, path: String? = nil) {
        self.model = model
        self.path = path ?? ProcessInfo.processInfo.environment["WORKSCRIBE_TEXT_MODEL"]
            ?? RuntimeAssets.model(model.filename).path
    }

    var displayName: String { "\(model.displayName) · on this Mac" }
    var provider: String { "local" }
    var modelName: String { model.displayName }
    var isAvailable: Bool { RuntimeAssets.inspect(URL(fileURLWithPath: path)) == .present }

    func template(_ prompt: AskPrompt) -> String {
        let text = prompt.userText
        return model == .gemma4 ? NotePrompt.gemma(text)
            : "<|im_start|>user\n\(text)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }

    final class Sink: @unchecked Sendable {
        let continuation: AsyncThrowingStream<String, Error>.Continuation
        var cancelled = false
        init(_ continuation: AsyncThrowingStream<String, Error>.Continuation) { self.continuation = continuation }
    }

    func stream(_ prompt: AskPrompt) -> AsyncThrowingStream<String, Error> {
        let text = template(prompt), path = self.path
        return AsyncThrowingStream { continuation in
            let sink = Sink(continuation)
            continuation.onTermination = { _ in sink.cancelled = true }
            Self.queue.async {
                do { try RuntimeAssets.require(URL(fileURLWithPath: path)) }
                catch { continuation.finish(throwing: error); return }
                var error = [CChar](repeating: 0, count: 512)
                let context = Unmanaged.passRetained(sink).toOpaque()
                defer { Unmanaged<Sink>.fromOpaque(context).release() }
                let status = ws_generate_text_stream(path, text, 8192, 320, nil, { piece, context in
                    guard let piece, let context else { return 1 }
                    let sink = Unmanaged<Sink>.fromOpaque(context).takeUnretainedValue()
                    if sink.cancelled { return 1 }
                    sink.continuation.yield(String(cString: piece))
                    return 0
                }, context, &error, error.count)
                if status != 0 { continuation.finish(throwing: CaptureError.message(String(cString: error))) }
                else { continuation.finish() }
            }
        }
    }
}

#if canImport(FoundationModels)
/// Apple Intelligence's on-device model (macOS 26). Available only when Apple Intelligence is turned on.
struct AppleIntelligenceAnswerGenerator: AnswerGenerator {
    var displayName: String { "Apple Intelligence · on this Mac" }
    var provider: String { "local" }
    var modelName: String { "Apple Foundation Model" }
    var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    func stream(_ prompt: AskPrompt) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(instructions: prompt.instruction)
                    var request = "Sources:\n" + (prompt.sources.isEmpty ? "(none)" : prompt.sources)
                    if !prompt.history.isEmpty {
                        request += "\n\nEarlier in this chat:\n" + prompt.history.map { "Q: \($0.question)\nA: \($0.answer)" }.joined(separator: "\n")
                    }
                    request += "\n\nQuestion: " + prompt.question
                    var previous = ""
                    for try await snapshot in session.streamResponse(to: request) {
                        let content = snapshot.content
                        if content.hasPrefix(previous) { continuation.yield(String(content.dropFirst(previous.count))) }
                        previous = content
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
