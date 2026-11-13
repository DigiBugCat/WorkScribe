import Foundation
import WorkScribeCore

/// Writes a short cited answer from the moments retrieval found.
protocol AnswerGenerator: Sendable {
    /// "Codex · gpt-6.1-sol": shown under answers and in the composer footer.
    var displayName: String { get }
    /// "codex" (for /v1/status).
    var provider: String { get }
    /// The model's name.
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
    /// Answers are written by Codex. "none" in the "answerEngine" setting lists the matching moments instead.
    static func preferred(setting: String = UserDefaults.standard.string(forKey: "answerEngine") ?? "auto") -> (any AnswerGenerator)? {
        setting == "none" ? nil : CodexAnswerGenerator()
    }
}

/// Answers through the text backend. The request carries the question and the retrieved excerpts
/// (`AskPrompt`), never a whole transcript.
struct CodexAnswerGenerator: AnswerGenerator {
    var model: any TextModel = TextModels.model(for: .ask)
    var displayName: String { model.displayName }
    var provider: String { "codex" }
    var modelName: String { CodexStatus.current.model ?? "Codex" }
    var isAvailable: Bool { model.isAvailable }
    func stream(_ prompt: AskPrompt) -> AsyncThrowingStream<String, Error> {
        model.stream(TextRequest(prompt.userText, maxTokens: 320))
    }
}
