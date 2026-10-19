@preconcurrency import CoreML
import FluidUse
import Foundation
import CoreGraphics
import WorkScribeCore

/// EmbeddingGemma 2 on Core ML (FluidUse): text on the Neural Engine, 10 s audio windows on the GPU, both into the
/// same 768-d space. The optional vision wrapper embeds image files on the GPU. Loaded from the files bundled at build time (`scripts/prepare-embedding-model.py`); the app never
/// downloads models. Like the title model, it loads on demand and lets go of its memory once idle.
actor CoreMLEmbedder: Embedder {
    nonisolated let directory: URL
    nonisolated let modelID: String
    nonisolated let dimension = EmbeddingGemma2Manager.dimension
    nonisolated let supportsAudio: Bool
    nonisolated let supportsImages: Bool
    private var visionModel: EmbeddingGemmaVision?
    /// Release the models after this long without a call.
    let idleSeconds: Double

    private var text: EmbeddingGemma2Manager?
    private var audioModel: EmbeddingGemma2Audio?
    private var loading: Task<EmbeddingGemma2Manager, Error>?
    private var idleTask: Task<Void, Never>?
    private(set) var lastLoadSeconds: Double?

    static let folderName = "embeddinggemma-2-coreml"

    /// The bundled model, or the folder in `WORKSCRIBE_EMBEDDING_DIR` (development). Nil when the text model is absent:
    /// search then works by words only.
    static func bundled(idleSeconds: Double = 120) -> CoreMLEmbedder? {
        let environment = ProcessInfo.processInfo.environment["WORKSCRIBE_EMBEDDING_DIR"].map { URL(fileURLWithPath: $0) }
        let bundled = RuntimeAssets.model(folderName)
        for candidate in [environment, bundled].compactMap({ $0 }) {
            if let embedder = CoreMLEmbedder(directory: candidate, idleSeconds: idleSeconds) { return embedder }
        }
        return nil
    }

    init?(directory: URL, idleSeconds: Double = 120) {
        let manager = FileManager.default
        let textModel = directory.appendingPathComponent("EmbeddingGemma2Text.mlmodelc")
        guard RuntimeAssets.inspect(textModel) == .present,
              NoteImageContent.isMaterialized(directory.appendingPathComponent("embeddings.bf16")),
              manager.fileExists(atPath: directory.appendingPathComponent("embeddings.bf16").path),
              manager.fileExists(atPath: directory.appendingPathComponent("tokenizer.json").path) else { return nil }
        func revision(_ package: String) -> String? {
            (try? String(contentsOf: directory.appendingPathComponent("\(package).mlmodelc/workscribe-revision"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(8).description
        }
        let audio = RuntimeAssets.inspect(directory.appendingPathComponent("EmbeddingGemma2Audio.mlmodelc")) == .present
        self.directory = directory
        self.supportsAudio = audio
        self.supportsImages = EmbeddingGemmaVision.available(in: directory)
        self.idleSeconds = idleSeconds
        // Audio windows are embedded through the text model, so both revisions shape audio vectors.
        modelID = "embeddinggemma-2-coreml/text@\(revision("EmbeddingGemma2Text") ?? "unknown")"
            + (audio ? "+audio@\(revision("EmbeddingGemma2Audio") ?? "unknown")" : "") + (self.supportsImages ? "+vision70@\(revision("EmbeddingGemma2Vision") ?? "unknown")" : "") + "/768"
    }

    func text(_ value: String, role: TextRole) async throws -> [Float] {
        try await texts([value], role: role)[0]
    }

    func texts(_ values: [String], role: TextRole) async throws -> [[Float]] {
        guard !values.isEmpty else { return [] }
        let manager = try await loadText()
        defer { scheduleRelease() }
        let prompt: EmbeddingGemma2Prompt = switch role {
        case .query: .searchQuery
        case .document(let title): .document(title: title.flatMap { $0.isEmpty ? nil : $0 })
        }
        return try await manager.embed(values, prompt: prompt).map {
            guard let vector = VectorMath.normalized($0), vector.count == dimension else {
                throw EmbedderError.badVector("\($0.count) values")
            }
            return vector
        }
    }

    func audio(_ pcm16k: [Float]) async throws -> [Float] {
        guard supportsAudio else { throw EmbedderError.audioUnsupported }
        guard !pcm16k.isEmpty, pcm16k.count <= Embedders.audioWindowSamples else {
            throw EmbedderError.badVector("audio window of \(pcm16k.count) samples")
        }
        let manager = try await loadText()
        if audioModel == nil {
            // FluidUse loads audio only through its environment override or its download store; point the override
            // at the bundled folder so nothing is ever downloaded.
            setenv("EMBEDDINGGEMMA2_MODEL_DIR", directory.path, 1)
            try RuntimeAssets.require(directory.appendingPathComponent("EmbeddingGemma2Audio.mlmodelc"))
            audioModel = try await EmbeddingGemma2Audio.load(text: manager, computeUnits: .cpuAndGPU)
        }
        defer { scheduleRelease() }
        guard let vector = VectorMath.normalized(try await audioModel!.embed(window: pcm16k)) else {
            throw EmbedderError.badVector("audio")
        }
        return vector
    }

    func image(_ url: URL) async throws -> [Float] {
        guard supportsImages else { throw EmbedderError.imageUnsupported }
        if visionModel == nil { visionModel = EmbeddingGemmaVision(directory: directory) }
        defer { scheduleRelease() }
        return try await visionModel!.embed(url)
    }

    func image(_ image: CGImage) async throws -> [Float] {
        guard supportsImages else { throw EmbedderError.imageUnsupported }
        if visionModel == nil { visionModel = EmbeddingGemmaVision(directory: directory) }
        defer { scheduleRelease() }
        return try await visionModel!.embed(image)
    }

    /// Lets go of the models now (recording started, or the app is idle).
    func release() {
        idleTask?.cancel(); idleTask = nil
        loading = nil; text = nil; audioModel = nil
        let oldVision = visionModel; visionModel = nil
        Task { await oldVision?.release() }
    }

    var isLoaded: Bool { text != nil }

    private func loadText() async throws -> EmbeddingGemma2Manager {
        idleTask?.cancel(); idleTask = nil
        if let text { return text }
        if loading == nil {
            let directory = directory
            loading = Task {
                for file in ["EmbeddingGemma2Text.mlmodelc", "embeddings.bf16", "tokenizer.json"] {
                    try RuntimeAssets.require(directory.appendingPathComponent(file))
                }
                return try await EmbeddingGemma2Manager.load(from: directory, computeUnits: .cpuAndNeuralEngine)
            }
        }
        let started = Date()
        do {
            let manager = try await loading!.value
            if text == nil { lastLoadSeconds = Date().timeIntervalSince(started) }
            text = manager
            loading = nil // The completed task must not retain a second ownership path past release.
            return manager
        } catch {
            loading = nil
            throw EmbedderError.unavailable(error.localizedDescription)
        }
    }

    private func scheduleRelease() {
        idleTask?.cancel()
        let seconds = idleSeconds
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.release()
        }
    }
}
