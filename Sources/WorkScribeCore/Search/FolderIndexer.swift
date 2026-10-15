import CommonCrypto
import Foundation

/// A passage of a file: a PDF page, a stretch of a document, an image's recognized text.
public struct Passage: Sendable, Equatable {
    public var text: String
    public var page: Int?
    public init(text: String, page: Int? = nil) { self.text = text; self.page = page }
}

/// A 16 kHz mono window of a recording (≤ 10 s), with its place in the file.
public struct AudioWindow: Sendable {
    public var start: Double
    public var end: Double
    public var samples: [Float]
    public init(start: Double, end: Double, samples: [Float]) { self.start = start; self.end = end; self.samples = samples }
}

/// Reads files for the index. The app's implementation uses PDFKit, the Cocoa text system, Vision and AVFoundation;
/// `PlainTextExtractor` covers plain text, Markdown and HTML with Foundation alone.
public protocol FileExtracting: Sendable {
    func passages(of url: URL, kind: ChunkKind) async throws -> (title: String?, passages: [Passage])
    /// Calls `body` with each non-silent 10 s window of the file's audio (a video's soundtrack), in order.
    func audioWindows(of url: URL, _ body: (AudioWindow) async throws -> Void) async throws
}

public struct PlainTextExtractor: FileExtracting {
    public init() {}
    public func passages(of url: URL, kind: ChunkKind) async throws -> (title: String?, passages: [Passage]) {
        guard kind == .document else { return (nil, []) }
        let ext = url.pathExtension.lowercased()
        guard ["txt", "text", "md", "markdown", "html", "htm"].contains(ext) else { throw FolderIndexer.Skip.unsupported(ext) }
        var encoding = String.Encoding.utf8
        let raw = try (try? String(contentsOf: url, usedEncoding: &encoding)) ?? String(contentsOf: url, encoding: .isoLatin1)
        let text = ext.hasPrefix("htm") ? TextChunker.plainText(fromHTML: raw) : raw
        return (nil, TextChunker.chunks(text).map { Passage(text: $0) })
    }
    public func audioWindows(of url: URL, _ body: (AudioWindow) async throws -> Void) async throws {
        throw FolderIndexer.Skip.unsupported(url.pathExtension)
    }
}

/// Keeps the index in step with the folders the user added: new and edited files are read and embedded, touched but
/// unchanged files (same content hash) only get their new fingerprint, deleted files leave the index.
public struct FolderIndexer: Sendable {
    public enum Skip: Error, CustomStringConvertible {
        case unsupported(String), noAudioModel, empty, tooLarge
        public var description: String {
            switch self {
            case .unsupported(let ext): "unsupported type .\(ext)"
            case .noAudioModel: "needs the audio embedding model"
            case .empty: "no text or sound"
            case .tooLarge: "too large"
            }
        }
    }

    public let index: SearchIndex
    public let embedder: (any Embedder)?
    public let extractor: any FileExtracting
    public let gate: @Sendable () async -> Void
    /// Files up to this size get a content hash, so a touch without an edit doesn't re-embed them.
    public var hashLimit = 64 * 1024 * 1024
    /// Recordings longer than this are skipped (a 3-hour podcast is ~1,000 windows).
    public var maximumAudioSeconds = 4 * 3600.0

    public init(index: SearchIndex, embedder: (any Embedder)?, extractor: any FileExtracting = PlainTextExtractor(),
                gate: @escaping @Sendable () async -> Void = {}) {
        self.index = index; self.embedder = embedder; self.extractor = extractor; self.gate = gate
    }

    public func sync() async throws -> IndexReport {
        if let embedder { try index.adopt(modelID: embedder.modelID) }
        var report = IndexReport()
        var seen = Set<String>()
        for root in try index.folders() {
            for (url, kind) in FolderRules.walk(URL(fileURLWithPath: root)) {
                try Task.checkCancellation()
                guard seen.insert(url.path).inserted else { continue }
                do {
                    switch try await index(url, kind: kind, root: root) {
                    case .indexed: report.indexed += 1
                    case .refreshed: report.refreshed += 1
                    case .unchanged: report.unchanged += 1
                    case .skipped: report.skipped += 1
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { report.failed += 1 }
            }
        }
        // Attachments aren't in any folder; they leave the index with their conversation or meeting.
        for source in try index.sources(kind: .file) where !seen.contains(source.ref) && !AttachmentOwner.isAttachmentRoot(source.root) {
            try index.remove(ref: source.ref); report.removed += 1
        }
        return report
    }

    public enum Outcome: Sendable { case indexed, refreshed, unchanged, skipped }

    public static func fingerprint(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "f1:\(values.fileSize ?? 0):\(Int64(((values.contentModificationDate?.timeIntervalSince1970) ?? 0) * 1000))"
    }

    /// SHA-256 of the file, streamed.
    public static func contentHash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)
        while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty {
            block.withUnsafeBytes { _ = CC_SHA256_Update(&context, $0.baseAddress, CC_LONG(block.count)) }
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    public func index(_ url: URL, kind: ChunkKind, root: String) async throws -> Outcome {
        let ref = url.path
        let fingerprint = try Self.fingerprint(url)
        let existing = try index.source(ref: ref)
        let retryAudio = existing?.detail == Skip.noAudioModel.description && embedder?.supportsAudio == true
        let modelCurrent = !retryAudio
            && (embedder == nil || existing?.modelID == embedder?.modelID || existing?.state == "skipped")
        if let existing, existing.fingerprint == fingerprint, modelCurrent { return .unchanged }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let hash = size <= hashLimit ? try Self.contentHash(url) : nil
        if let existing, let hash, existing.contentHash == hash, modelCurrent {
            try index.touch(ref: ref, fingerprint: fingerprint)
            return .refreshed
        }
        let title = url.lastPathComponent
        do {
            let chunks = try await read(url, kind: kind)
            guard !chunks.isEmpty else { throw Skip.empty }
            try index.replace(kind: .file, ref: ref, root: root, title: title, fingerprint: fingerprint, contentHash: hash,
                              modelID: embedder?.modelID, chunks: chunks)
            return .indexed
        } catch let skip as Skip {
            // Remembered, so an unreadable file isn't retried until it changes.
            try index.replace(kind: .file, ref: ref, root: root, title: title, fingerprint: fingerprint, contentHash: hash,
                              modelID: nil, state: "skipped", detail: skip.description, chunks: [])
            return .skipped
        }
    }

    func read(_ url: URL, kind: ChunkKind) async throws -> [Chunk] {
        switch kind {
        case .document, .image:
            let (_, passages) = try await extractor.passages(of: url, kind: kind)
            var chunks = passages.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map {
                Chunk(kind: kind, modality: .text, page: $0.page, text: $0.text)
            }
            if let embedder {
                let rows = chunks.indices.filter { chunks[$0].text.map(SearchText.hasWords) ?? false }
                for batch in stride(from: 0, to: rows.count, by: 32) {
                    await gate()
                    try Task.checkCancellation()
                    let part = Array(rows[batch..<min(batch + 32, rows.count)])
                    let vectors = try await embedder.texts(part.map { chunks[$0].text ?? "" },
                                                           role: .document(title: url.deletingPathExtension().lastPathComponent))
                    for (row, vector) in zip(part, vectors) { chunks[row].vector = VectorMath.normalized(vector) }
                }
            }
            if kind == .image, let embedder, embedder.supportsImages {
                await gate(); try Task.checkCancellation()
                if let vector = try? await embedder.image(url) {
                    chunks.append(Chunk(kind: .image, modality: .image, text: url.deletingPathExtension().lastPathComponent,
                                        vector: VectorMath.normalized(vector), thumbnail: url.path))
                }
            }
            return chunks
        case .audio, .video:
            // A recording without the audio model is indexed by name only, and re-read once the model is there.
            guard let embedder, embedder.supportsAudio else { throw Skip.noAudioModel }
            var chunks: [Chunk] = []
            try await extractor.audioWindows(of: url) { window in
                guard window.start < maximumAudioSeconds else { throw Skip.tooLarge }
                guard TextChunker.rms(window.samples[...]) > TextChunker.silenceRMS else { return }
                await gate()
                try Task.checkCancellation()
                let vector = try await embedder.audio(window.samples)
                chunks.append(Chunk(kind: kind, modality: .audio, start: window.start, end: window.end,
                                    vector: VectorMath.normalized(vector)))
            }
            return chunks
        case .meetingSegment, .screen, .clip:
            return []
        }
    }
}
