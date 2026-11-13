import Foundation
import WorkScribeCore

extension Notification.Name {
    /// userInfo "state": "ready", "loading" or "missing". Posted when the text backend's state changes.
    static let workScribeTextModelState = Notification.Name("WorkScribeTextModelState")
}

/// One generation: the whole prompt as a single user message.
struct TextRequest: Sendable {
    var instruction: String
    /// Evaluation attribution only; never inserted into a model prompt.
    var noteID: String?
    /// An upper bound on the reply, in tokens. The backend turns it into a length ceiling.
    var maxTokens: Int
    var stop: String?
    /// Titles: stop at the first line break once the text is non-blank.
    var firstLine = false
    /// Pictures the model should look at along with the instruction.
    var images: [String] = []
    init(_ instruction: String, maxTokens: Int, stop: String? = nil, firstLine: Bool = false, noteID: String? = nil, images: [String] = []) {
        self.instruction = instruction; self.maxTokens = maxTokens; self.stop = stop; self.firstLine = firstLine
        self.noteID = noteID; self.images = images
    }
}

struct TextStats: Sendable, Codable, Equatable {
    var promptTokens = 0
    /// Prompt tokens the provider served from its cache.
    var reusedTokens = 0
    var generatedTokens = 0
    /// From the start of the request to the first piece of text.
    var ttftMs: Double = 0
    var totalMs: Double = 0
}

struct TextGeneration: Sendable {
    var text: String
    var stats: TextStats
}

/// The seam every text job goes through: note lines, briefs, topics, action wording, titles and Ask.
protocol TextModel: Sendable {
    /// What traces show: "Codex · gpt-6.1-sol".
    var displayName: String { get }
    /// Installed, signed in and not shut off. Cheap; never starts anything.
    var isAvailable: Bool { get }
    func generate(_ request: TextRequest) async throws -> TextGeneration
    /// Pieces as they arrive (Ask). Ending the stream early stops generation.
    func stream(_ request: TextRequest) -> AsyncThrowingStream<String, Error>
    /// Get ready ahead of the first request.
    func prewarm() async
    func release() async
}

/// Text written by Codex, through `codex app-server` (`CodexAppServer`, `CodexSession`).
/// What is sent is the prompt: the instruction and the excerpts retrieved for it.
struct CodexTextModel: TextModel {
    let server: CodexAppServer
    init(server: CodexAppServer = .shared) { self.server = server }

    var displayName: String { "Codex" + (CodexStatus.current.model.map { " · \($0)" } ?? "") }
    var isAvailable: Bool { CodexStatus.current.usable }

    func generate(_ request: TextRequest) async throws -> TextGeneration {
        try await run(request, onPiece: nil)
    }

    func stream(_ request: TextRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do { _ = try await run(request) { continuation.yield($0) }; continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func prewarm() async { await server.start() }
    func release() async { await server.shutdown() }

    private func run(_ request: TextRequest, onPiece: (@Sendable (String) -> Void)?) async throws -> TextGeneration {
        let started = ContinuousClock.now
        let first = FirstPiece()
        // About four characters a token, with room to spare: the ceiling stops a runaway reply, the
        // caller's own checks decide what is acceptable.
        let wanted = CodexRequest(prompt: request.instruction, images: request.images, stop: request.stop,
                                  firstLine: request.firstLine, maxCharacters: max(400, request.maxTokens * 8))
        let reply = try await server.generate(wanted) { piece in first.mark(); onPiece?(piece) }
        let total = (ContinuousClock.now - started).milliseconds
        return TextGeneration(text: reply.text, stats: TextStats(
            promptTokens: reply.usage.inputTokens, reusedTokens: reply.usage.cachedInputTokens,
            generatedTokens: reply.usage.outputTokens, ttftMs: first.elapsed(since: started) ?? total, totalMs: total))
    }

    private final class FirstPiece: @unchecked Sendable {
        private let lock = NSLock()
        private var at: ContinuousClock.Instant?
        func mark() { lock.withLock { if at == nil { at = .now } } }
        func elapsed(since start: ContinuousClock.Instant) -> Double? { lock.withLock { at.map { ($0 - start).milliseconds } } }
    }
}

extension Duration {
    var milliseconds: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}

enum TextJob: String, Sendable { case line, brief, title, ask }

enum TextModels {
    /// Every text job goes to Codex.
    static func model(for job: TextJob) -> any TextModel { CodexTextModel() }
}

/// A prompt's size, for keeping what is sent bounded. An estimate (about four characters a token),
/// not the provider's tokenizer: the budgets it enforces are about how much text leaves this Mac
/// and how long a reply takes, not a hard context limit.
enum PromptSize {
    static func tokens(_ text: String) -> Int { (text.utf8.count + 3) / 4 }
}
