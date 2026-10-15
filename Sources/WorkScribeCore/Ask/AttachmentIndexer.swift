import Foundation

/// Indexes attachments as file sources whose root is their owner's `indexRoot`, with the same extractors and embedder
/// as folders. A type nothing can read is still recorded (as skipped, with the reason) so its chip can say why.
public struct AttachmentIndexer: Sendable {
    public let folders: FolderIndexer
    public init(folders: FolderIndexer) { self.folders = folders }

    /// The resulting `indexState` for the attachment's chip.
    public func index(_ url: URL, owner: AttachmentOwner) async -> String {
        let kind = FolderRules.kind(of: url) ?? .document
        do {
            if let embedder = folders.embedder { try folders.index.adopt(modelID: embedder.modelID) }
            _ = try await folders.index(url, kind: kind, root: owner.indexRoot)
            let source = try folders.index.source(ref: url.path)
            return source?.state == "skipped" ? (source?.detail ?? "skipped") : "indexed"
        } catch {
            return "couldn't read: \(error)"
        }
    }

    /// Sources indexed for `owner`, by ref (a conversation's or meeting's attachments).
    public static func refs(in index: SearchIndex, owner: AttachmentOwner) -> Set<String> {
        Set(((try? index.sources(kind: .file)) ?? []).filter { $0.root == owner.indexRoot }.map(\.ref))
    }

    /// Drops attachment sources whose file is gone (the conversation or meeting was deleted).
    @discardableResult
    public static func prune(_ index: SearchIndex) -> Int {
        var removed = 0
        for source in (try? index.sources(kind: .file)) ?? [] where AttachmentOwner.isAttachmentRoot(source.root) {
            if !FileManager.default.fileExists(atPath: source.ref) { try? index.remove(ref: source.ref); removed += 1 }
        }
        return removed
    }
}
