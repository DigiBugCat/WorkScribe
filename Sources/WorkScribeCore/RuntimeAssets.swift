import Foundation
import CryptoKit
import Darwin

/// Shared preflight for every native model boundary. Never opens a dataless file to hash it.
public enum RuntimeAssets {
    public enum State: String { case present, evicted, missing; case wrongHash = "wrong hash" }
    public static var home: URL {
        if let path = ProcessInfo.processInfo.environment["WORKSCRIBE_RUNTIME_HOME"] { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WorkScribe/Runtime")
    }
    public static func model(_ name: String) -> URL {
        if let root = ProcessInfo.processInfo.environment["WORKSCRIBE_RUNTIME_HOME"] {
            return URL(fileURLWithPath: root).appendingPathComponent("models/\(name)")
        }
        let local = home.appendingPathComponent("models/\(name)")
        if FileManager.default.fileExists(atPath: local.path) { return local }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Models/\(name)")
    }
    /// Metadata seam makes SF_DATALESS testable without evicting any user files.
    public static func metadataState(exists: Bool, size: Int64, flags: UInt32) -> State {
        if !exists { return .missing }
        if flags & 0x40000000 != 0 { return .evicted } // Darwin SF_DATALESS
        return size > 0 ? .present : .wrongHash
    }
    private static let cacheLock = NSLock()
    private static var verified = Set<String>()

    public static func inspect(_ url: URL, expected: String? = nil, manifest: [String: String]? = nil) -> State {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return .missing }
        if info.st_flags & 0x40000000 != 0 { return .evicted }
        if (info.st_mode & S_IFMT) == S_IFDIR {
            // Enumerating only surviving files would miss an evicted/deleted weight shard.
            let expectedFiles = manifest ?? directoryManifest(for: url)
            if url.pathExtension == "mlmodelc" && url.path.hasPrefix(home.path + "/") && expectedFiles.isEmpty {
                return .wrongHash // Imported graphs must be verified/rebuilt by doctor before use.
            }
            for (relative, digest) in expectedFiles {
                let state = inspect(url.appendingPathComponent(relative), expected: digest)
                if state != .present { return state }
            }
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return .missing }
            var files = 0
            while let child = enumerator.nextObject() as? URL {
                var childInfo = stat()
                guard stat(child.path, &childInfo) == 0 else { return .missing }
                if childInfo.st_flags & 0x40000000 != 0 { return .evicted }
                if (childInfo.st_mode & S_IFMT) == S_IFREG {
                    files += 1
                    let state = inspect(child)
                    if state != .present { return state }
                }
            }
            return files > 0 ? .present : .missing
        }
        let state = metadataState(exists: true, size: info.st_size, flags: info.st_flags)
        guard state == .present else { return state }
        let digest = expected ?? pinned[url.lastPathComponent] ?? sourceDigest(for: url) ?? receipt(for: url)
        guard let digest else { return .present } // locally built assets have no upstream digest
        let identity = "\(url.path):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec):\(digest)"
        cacheLock.lock()
        let cached = verified.contains(identity)
        cacheLock.unlock()
        if cached { return .present }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .missing }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        } catch { return .missing }
        guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == digest else { return .wrongHash }
        cacheLock.lock()
        if verified.count > 2048 { verified.removeAll() }
        verified.insert(identity)
        cacheLock.unlock()
        return .present
    }
    public static func require(_ url: URL) throws {
        let state = inspect(url)
        guard state == .present else { throw ReadinessError(path: url.path, state: state) }
    }
    public struct ReadinessError: LocalizedError {
        let path: String
        let state: State
        public var errorDescription: String? { "\(URL(fileURLWithPath: path).lastPathComponent): \(state.rawValue). Run WorkScribe --doctor to get models ready." }
    }
    private static let pinned = [
        "nemotron-3.5-asr-streaming-0.6b.q8_0.gguf": "a5c435f294eea8f88ce68dd27b8c3bfea7f777cb2fbba04fcd30eaa555f429ae",
        "Nemotron-3-Diarization.q8_0.gguf": "08456d9e22cd9a323c0364d98375f3746d6e68507ebb705cd46438c534c7a3a1",
        "Qwen3.5-2B-Q4_K_M.gguf": "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223",
        "gemma-4-E2B_q4_0-it.gguf": "fa401b55b07ee70a54c6dae3903c783a6e65064312529ea57175cb5f8dec6634",
        "mmproj-gemma-4-E2B-it-Q8_0.gguf": "9406f99c16d68cda4f1f0552192dcc99021ea1fc6d2fd50b1dc3ccf30d04b292",
        "gemma-4-E2B-it-Q4_0.gguf": "8e30dff3ac4c8434c49a7036fa15564bdbb6044e42bf04550bf1a096ad7e6a52"
    ]
    private static func sourceDigest(for url: URL) -> String? {
        // Hashes of downloaded files, separate from receipts for locally compiled graphs.
        for (suffix, hash) in sourceHashes where url.path.hasSuffix("/" + suffix) { return hash }
        return nil
    }
    private static let sourceHashes: [String: String] = [
        "wespeaker_v2.mlmodelc/metadata.json": "ddc4858b4051254098015cd0b97080149839d697faf7b036f933190e70b26758",
        "wespeaker_v2.mlmodelc/model.mil": "2850f775d6ba659f01f616fed77ce6a45a25de3eb7e4bf3a4b07b658be4e13dd",
        "wespeaker_v2.mlmodelc/coremldata.bin": "6feb2472a71fa9d8a84020c85206138a4f6261c565c9884bf518d59dd5838da7",
        "wespeaker_v2.mlmodelc/weights/weight.bin": "34004f6798d35cad7071e2fdc67e63faaa782f53697e1cb49bcb452cf81ae151",
        "wespeaker_v2.mlmodelc/analytics/coremldata.bin": "d2b1fcde6121aea3ff0e14c1dc50d09dacb0314a2e89156353c31804230a422f",
        "embeddinggemma-2-coreml/config.json": "4ff891a28a5d55562b55ff3aa4ef362968d378629f9453f337cb70a9e1b45f61",
        "embeddinggemma-2-coreml/tokenizer.json": "4d777ef5bdc1aa36227abdfb77c3e49e7b9c892d16e1b6bda41c393504828be4",
        "embeddinggemma-2-coreml/embeddings.bf16": "56ebbdbfd706c827f3fae1d97aa39135c7ddc0f1e6d9b12f8565f84bbfbda877",
        "embeddinggemma-2-coreml/position_embeddings.f16": "17de9480acc23638c0634a97ed89e51ed664433256d7d6f109587dcd91c79124",
    ]
    private static func directoryManifest(for url: URL) -> [String: String] {
        var result: [String: String] = [:]
        let prefix = url.lastPathComponent + "/"
        for (path, hash) in sourceHashes where path.hasPrefix(prefix) {
            result[String(path.dropFirst(prefix.count))] = hash
        }
        if url.path.hasPrefix(home.path + "/"),
           let data = try? Data(contentsOf: home.appendingPathComponent("checksums.json")),
           let receipts = try? JSONDecoder().decode([String:String].self, from: data) {
            let relative = String(url.path.dropFirst(home.path.count + 1)) + "/"
            for (path, hash) in receipts where path.hasPrefix(relative) {
                let file = String(path.dropFirst(relative.count))
                if result[file] == nil { result[file] = hash }
            }
        }
        return result
    }
    private static func receipt(for url: URL) -> String? {
        guard url.path.hasPrefix(home.path + "/"),
              let data = try? Data(contentsOf: home.appendingPathComponent("checksums.json")),
              let hashes = try? JSONDecoder().decode([String:String].self, from: data) else { return nil }
        return hashes[String(url.path.dropFirst(home.path.count + 1))]
    }
}
