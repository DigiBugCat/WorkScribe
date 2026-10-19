import Foundation
import WorkScribeCore

extension Notification.Name {
    static let workScribeTextModelState = Notification.Name("WorkScribeTextModelState")
}

/// One generation. `instruction` is the user turn without a chat template; each backend wraps it
/// in its own model's template.
struct TextRequest: Sendable {
    var instruction: String
    /// Evaluation attribution only; never inserted into a model prompt.
    var noteID: String?
    /// The leading part of `instruction` that is the same on every call of this kind (the fixed
    /// rules of a prompt). Backends keep its prefilled state and restore it instead of prefilling it
    /// again. Ignored unless `instruction` starts with it.
    var cacheablePrefix: String?
    var maxTokens: Int
    var stop: String?
    /// Titles: stop at the first line break once the text is non-blank.
    var firstLine = false
    init(_ instruction: String, cacheablePrefix: String? = nil, maxTokens: Int, stop: String? = nil, firstLine: Bool = false, noteID: String? = nil) {
        self.instruction = instruction; self.maxTokens = maxTokens; self.stop = stop; self.firstLine = firstLine
        self.noteID = noteID
        self.cacheablePrefix = cacheablePrefix.flatMap { instruction.hasPrefix($0) ? $0 : nil }
    }
}

struct TextStats: Sendable, Codable, Equatable {
    var promptTokens = 0
    /// Prompt tokens restored from a saved prefix state instead of prefilled.
    var reusedTokens = 0
    var generatedTokens = 0
    /// This call prefilled the prefix and saved its state.
    var prefixBuilt = false
    /// Nonzero only on the call that loaded the model (load and first-use setup).
    var loadMs: Double = 0
    var prefillMs: Double = 0
    /// From the start of the request (template and tokenizing included) to the first sampled token.
    var ttftMs: Double = 0
    var totalMs: Double = 0
}

struct TextGeneration: Sendable {
    var text: String
    var stats: TextStats
}

enum TextBackend: String, Sendable { case llama = "llama.cpp" }

/// The seam every on-device text job goes through: live lines, final lines (with their topics and
/// action wording), briefs, titles and Ask. Implementations keep their model resident
/// (`ResidentTextModel`); `TextModels` picks one per job.
protocol TextModel: Sendable {
    /// What traces show, backend included: "Gemma 4 E4B · llama.cpp".
    var displayName: String { get }
    var backend: TextBackend { get }
    /// Weights present and verified. Hashes on first use.
    var isAvailable: Bool { get }
    func generate(_ request: TextRequest) async throws -> TextGeneration
    /// Pieces as they decode (Ask). Ending the stream early stops generation.
    func stream(_ request: TextRequest) -> AsyncThrowingStream<String, Error>
    /// When not loaded: load now, compile kernels and save `request`'s prefix state, so the next
    /// call is warm.
    func prewarm(_ request: TextRequest?) async
    func release() async
}

/// Cancellation and streaming for one generation, shared between the caller and the engine's queue.
final class GenerationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    /// Receives each decoded piece; returning false stops generation.
    let onPiece: (@Sendable (String) -> Bool)?
    init(onPiece: (@Sendable (String) -> Bool)? = nil) { self.onPiece = onPiece }
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// A backend's loaded model. Only `ResidentTextModel` calls it, always on that model's serial queue.
protocol TextEngine: AnyObject {
    var isLoaded: Bool { get }
    func load() throws
    /// Throws `CancellationError` when `control` is cancelled mid-way.
    func generate(_ request: TextRequest, control: GenerationControl) throws -> TextGeneration
    /// Memory pressure: drop saved prefix states and reusable buffers, keep the weights.
    func dropCaches()
    func unload()
}

/// Keeps one backend's model loaded between calls. It is loaded on first use and reused by every
/// call, never reloaded per call. It is released after `idleTimeout` without a call, or as soon
/// as macOS reports memory pressure (after the call in flight, if any).
///
/// Idle timeout: 5 minutes. Live lines arrive every 4–15 s while notes are typed, Stop runs the
/// final lines, topics, actions and brief back to back, and the title follows within a minute, so
/// five minutes keeps one meeting's work on a single load. After idle or memory pressure, release
/// the model; `prewarm` can load it again before the next note request.
actor ResidentTextModel: TextModel {
    static let idleTimeout: Duration = .seconds(300)
    nonisolated let displayName: String
    nonisolated let backend: TextBackend
    private nonisolated let availability: @Sendable () -> Bool
    nonisolated var isAvailable: Bool { availability() }
    private nonisolated let engine: EngineBox
    private nonisolated let queue: DispatchQueue
    private let idleTimeout: Duration
    private var active = 0
    private var lastUse = ContinuousClock.now
    private var idleTask: Task<Void, Never>?
    private var releaseWhenIdle = false
    /// How many times the weights were loaded (diagnostics and tests).
    private(set) var loads = 0

    /// Only ever touched on `queue`.
    final class EngineBox: @unchecked Sendable { let engine: any TextEngine; init(_ engine: any TextEngine) { self.engine = engine } }

    init(displayName: String, backend: TextBackend, engine: any TextEngine, idleTimeout: Duration = ResidentTextModel.idleTimeout,
         available: @escaping @Sendable () -> Bool) {
        self.displayName = displayName; self.backend = backend; self.availability = available
        self.engine = EngineBox(engine); self.idleTimeout = idleTimeout
        self.queue = DispatchQueue(label: "WorkScribe.text.\(backend.rawValue)", qos: .userInitiated)
        TextModelMemory.watch(self)
    }

    func generate(_ request: TextRequest) async throws -> TextGeneration {
        try await run(request, control: GenerationControl())
    }

    nonisolated func stream(_ request: TextRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let control = GenerationControl { piece in
                if case .terminated = continuation.yield(piece) { return false }
                return true
            }
            let task = Task {
                do { _ = try await self.run(request, control: control); continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in control.cancel(); task.cancel() }
        }
    }

    /// Loads the weights, compiles the kernels and saves `request`'s prefix state, unless the model
    /// is already loaded (then the next real call is warm anyway).
    func prewarm(_ request: TextRequest?) async {
        guard await !isLoaded else { return }
        _ = try? await run(request ?? TextRequest("Reply with one word.", maxTokens: 1), control: GenerationControl())
    }

    var isLoaded: Bool { get async { await onQueue { $0.isLoaded } } }

    /// Hands the weights back now, after any call in flight.
    func release() async {
        idleTask?.cancel(); idleTask = nil
        await onQueue { $0.unload() }
    }

    /// Memory pressure: drop the saved prefix states (on the engine's queue,
    /// so after the call in flight), then release the weights, or as soon as the calls in flight finish.
    func memoryPressure() async {
        await onQueue { $0.dropCaches() }
        if active == 0 { await release() } else { releaseWhenIdle = true }
    }

    private func run(_ request: TextRequest, control: GenerationControl) async throws -> TextGeneration {
        active += 1
        idleTask?.cancel(); idleTask = nil
        defer {
            active -= 1
            lastUse = .now
            if active == 0 {
                if releaseWhenIdle { releaseWhenIdle = false; Task { await self.release() } }
                else { scheduleIdleRelease() }
            }
        }
        let box = engine, queue = self.queue
        let result: (TextGeneration, Bool) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        var loaded = false, loadMs = 0.0
                        if !box.engine.isLoaded {
                            let started = ContinuousClock.now
                            NotificationCenter.default.post(name: .workScribeTextModelState, object: nil, userInfo: ["state": "loading"])
                            do { try box.engine.load() }
                            catch {
                                NotificationCenter.default.post(name: .workScribeTextModelState, object: nil, userInfo: ["state": "missing"])
                                throw error
                            }
                            NotificationCenter.default.post(name: .workScribeTextModelState, object: nil, userInfo: ["state": "ready"])
                            loaded = true; loadMs = (ContinuousClock.now - started).milliseconds
                        }
                        if control.isCancelled { throw CancellationError() }
                        var generation = try box.engine.generate(request, control: control)
                        generation.stats.loadMs = loadMs
                        continuation.resume(returning: (generation, loaded))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { control.cancel() }
        if result.1 { loads += 1 }
        return result.0
    }

    private func scheduleIdleRelease() {
        let timeout = idleTimeout
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            await self.releaseIfIdle()
        }
    }

    private func releaseIfIdle() async {
        guard active == 0, ContinuousClock.now - lastUse >= idleTimeout else { return }
        await release()
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable (any TextEngine) -> T) async -> T {
        let box = engine
        return await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: work(box.engine)) } }
    }
}

extension Duration {
    var milliseconds: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}

/// Releases every resident text model when macOS reports memory pressure (warning or critical).
enum TextModelMemory {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var models: [WeakModel] = []
    nonisolated(unsafe) private static var source: DispatchSourceMemoryPressure?
    private final class WeakModel { weak var model: ResidentTextModel?; init(_ model: ResidentTextModel) { self.model = model } }

    static func watch(_ model: ResidentTextModel) {
        lock.withLock {
            models.removeAll { $0.model == nil }
            models.append(WeakModel(model))
            guard source == nil else { return }
            let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
            pressure.setEventHandler {
                let current = lock.withLock { models.compactMap(\.model) }
                for model in current { Task { await model.memoryPressure() } }
            }
            pressure.activate()
            source = pressure
        }
    }
}

/// All production text jobs share the resident E4B llama.cpp model and prefix cache.
enum TextJob: String, Sendable { case line, brief, title, ask }

enum TextModels {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var llamaModels: [String: ResidentTextModel] = [:]

    /// The resident llama.cpp model for this GGUF (the bundled title model unless given).
    static func generator(_ model: GeneratorModel = .bundled, path: String? = nil) -> ResidentTextModel {
        let path = path ?? ProcessInfo.processInfo.environment["WORKSCRIBE_TEXT_MODEL"] ?? RuntimeAssets.model(model.filename).path
        return lock.withLock {
            if let existing = llamaModels[path] { return existing }
            let created = LlamaTextEngine.resident(model: model, path: path)
            llamaModels[path] = created
            return created
        }
    }

    static func model(for job: TextJob) -> any TextModel {
        generator(.gemma4)
    }
}
