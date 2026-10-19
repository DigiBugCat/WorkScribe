import Foundation
import WorkScribeCore

/// Writes a short cited answer using the resident E4B model.
protocol AnswerGenerator: Sendable {
    /// "Gemma 4 E4B · on this Mac": shown under answers and in the composer footer.
    var displayName: String { get }
    /// "local" (for /v1/status). Every generator runs on this Mac.
    var provider: String { get }
    /// The model's name ("Gemma 4 E4B").
    var modelName: String { get }
    var isAvailable: Bool { get }
    func stream(_ prompt: AskPrompt) -> AsyncThrowingStream<String, Error>
    func stream(_ prompt: AskPrompt, provenance: AnswerProvenance) -> AsyncThrowingStream<String, Error>
}
/// Per-request metadata, so parallel questions cannot borrow each other's model identity.
final class AnswerProvenance: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (String, String) = ("", "")
    func set(model: String, provider: String) {
        lock.lock(); defer { lock.unlock() }; value = (model, provider)
    }
    func snapshot() -> (model: String, provider: String) {
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
    /// Answers are written on this Mac only. There is no cloud model and no network fallback.
    static func preferred() -> (any AnswerGenerator)? { onDevice() }

    /// Existing preferences other than "none" now use E4B.
    static func onDevice(setting: String = UserDefaults.standard.string(forKey: "answerEngine") ?? "auto") -> (any AnswerGenerator)? {
        let bundled = LlamaAnswerGenerator()
        return setting != "none" && bundled.isAvailable ? bundled : nil
    }
}

/// E4B on the resident llama.cpp engine
/// (`TextModels.generator`): loaded once, kept between answers, released when idle or under memory
/// pressure. `WORKSCRIBE_TEXT_MODEL` points at a GGUF for runs outside the app bundle.
final class LlamaAnswerGenerator: AnswerGenerator, @unchecked Sendable {
    let model: GeneratorModel
    let path: String

    init(model: GeneratorModel = .bundled, path: String? = nil) {
        self.model = model
        self.path = path ?? ProcessInfo.processInfo.environment["WORKSCRIBE_TEXT_MODEL"]
            ?? RuntimeAssets.model(model.filename).path
    }

    var displayName: String { "\(model.displayName) · on this Mac" }
    var provider: String { "local" }
    var modelName: String { model.displayName }
    var isAvailable: Bool { RuntimeAssets.inspect(URL(fileURLWithPath: path)) == .present }

    func stream(_ prompt: AskPrompt) -> AsyncThrowingStream<String, Error> {
        let path = self.path
        // The instruction and the "Sources:" heading are the same on every question.
        let request = TextRequest(prompt.userText, cacheablePrefix: prompt.instruction + "\n\nSources:\n", maxTokens: 320)
        do { try RuntimeAssets.require(URL(fileURLWithPath: path)) }
        catch { return AsyncThrowingStream { $0.finish(throwing: error) } }
        return TextModels.generator(model, path: path).stream(request)
    }
}
