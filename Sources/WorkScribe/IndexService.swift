import Foundation
import WorkScribeCore

/// Runs semantic indexing off the main thread: meetings after they're finalized, folders the user added. Pauses
/// while recording (speech recognition owns the Neural Engine and the CPU then) and releases the embedding model when
/// a pass ends. The UI asks it to search; nothing here touches views.
actor IndexService {
    let index: SearchIndex
    private(set) var embedder: CoreMLEmbedder?
    let store: MeetingStore
    private var paused = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var running: Task<Void, Never>?
    private var pendingMeetings = false
    private var pendingFolders = false
    /// The vault being indexed, and what changed in it since the last pass (nil paths = full rescan).
    private var vaultRoot: URL?
    private var pendingVault: (paths: Set<String>?, checkpoint: VaultWatcher.Checkpoint?)?
    private(set) var status = "Search index idle"
    private(set) var lastReport: (meetings: IndexReport?, folders: IndexReport?) = (nil, nil)
    private(set) var lastVaultReport: IndexReport?

    init(index: SearchIndex, store: MeetingStore, embedder: CoreMLEmbedder?) {
        self.index = index; self.store = store; self.embedder = embedder
    }

    /// The default index next to the meetings, with the bundled model when it is present.
    static func make(store: MeetingStore) -> IndexService? {
        guard let index = try? SearchIndex() else { return nil }
        return IndexService(index: index, store: store, embedder: CoreMLEmbedder.bundled())
    }

    /// Repair can finish after keyword-only search has already opened.
    func refreshRuntime() async {
        if embedder == nil { embedder = CoreMLEmbedder.bundled() }
        await meetingsChanged()
        await foldersChanged()
    }

    // MARK: Pause while recording

    func setPaused(_ value: Bool) async {
        paused = value
        if value { await embedder?.release() }
        else { let ready = waiters; waiters = []; ready.forEach { $0.resume() } }
    }

    /// Awaited before each embedding call.
    func waitWhilePaused() async {
        guard paused else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    // MARK: Indexing

    func meetingsChanged() { pendingMeetings = true; kick() }
    func foldersChanged() { pendingFolders = true; kick() }

    func addFolder(_ url: URL) throws {
        try index.addFolder(url.standardizedFileURL.path); foldersChanged()
    }
    func removeFolder(_ url: URL) throws {
        try index.removeFolder(url.standardizedFileURL.path)
    }
    func folders() throws -> [String] { try index.folders() }

    // MARK: Vault

    static func checkpointKey(_ root: URL) -> String { "vault_checkpoint:" + FileIdentity.url(root).path }

    /// Where indexing of `root` last got to; the watcher replays FSEvents from there.
    func vaultCheckpoint(_ root: URL) -> VaultWatcher.Checkpoint? {
        (try? index.meta(Self.checkpointKey(root))).flatMap { $0.flatMap(VaultWatcher.Checkpoint.init) }
    }

    /// Switches the indexed vault. The previous vault's notes leave the index; nil stops vault indexing.
    func setVault(_ root: URL?) {
        let old = vaultRoot
        vaultRoot = root.map(FileIdentity.url)
        if let old, old != vaultRoot {
            for source in (try? index.sources(kind: .vault)) ?? [] where source.root == old.path { try? index.remove(ref: source.ref) }
            try? index.setMeta(Self.checkpointKey(old), "")
        }
        pendingVault = nil
    }

    /// The watcher saw changes (`paths`) or asks for a rescan (`paths == nil`). The checkpoint is saved only after the
    /// pass finishes, so a crash mid-pass replays the same events.
    func vaultChanged(root: URL, paths: [String]?, checkpoint: VaultWatcher.Checkpoint?) {
        guard FileIdentity.url(root) == vaultRoot else { return }
        var merged = pendingVault ?? (paths: Set(), checkpoint: nil)
        if let paths, merged.paths != nil { merged.paths!.formUnion(paths) } else { merged.paths = nil }
        merged.checkpoint = checkpoint ?? merged.checkpoint
        pendingVault = merged
        kick()
    }

    private func kick() {
        guard running == nil else { return }
        running = Task.detached(priority: .utility) { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        let gate: @Sendable () async -> Void = { [weak self] in await self?.waitWhilePaused() }
        while pendingMeetings || pendingFolders || pendingVault != nil {
            if pendingMeetings {
                pendingMeetings = false
                status = "Indexing meetings…"
                lastReport.meetings = try? await MeetingIndexer(index: index, embedder: embedder, gate: gate).sync(store: store)
            }
            if pendingFolders {
                pendingFolders = false
                status = "Indexing folders…"
                lastReport.folders = try? await FolderIndexer(index: index, embedder: embedder, extractor: FileExtractors(), gate: gate).sync()
            }
            if let work = pendingVault, let root = vaultRoot {
                pendingVault = nil
                status = "Indexing notes…"
                let indexer = VaultIndexer(index: index, embedder: embedder, extractor: FileExtractors(), gate: gate)
                let report: IndexReport? = if let paths = work.paths { try? await indexer.update(paths: Array(paths), vault: root) }
                    else { try? await indexer.sync(vault: root) }
                lastVaultReport = report
                if report != nil, let checkpoint = work.checkpoint { try? index.setMeta(Self.checkpointKey(root), checkpoint.description) }
            } else { pendingVault = nil }
        }
        await embedder?.release()
        index.invalidate()   // vectors reload lazily on the next meaning search
        status = "Search index up to date"
        running = nil
    }

    // MARK: Search

    func search(_ request: SearchRequest) async throws -> SearchResults {
        var vector: [Float]?
        if !paused, let embedder, index.vectorModel == embedder.modelID, !request.text.trimmingCharacters(in: .whitespaces).isEmpty {
            vector = try? await embedder.text(request.text, role: .query)
        }
        return try index.search(request, queryVector: vector, queryModelID: paused ? nil : embedder?.modelID)
    }
}

extension IndexService {
    func purgeMeeting(_ id: String, folder: URL, conversationIDs: [String] = []) throws {
        var refs = [id]
        let roots = Set([AttachmentOwner.meeting(id).indexRoot] + conversationIDs.map { AttachmentOwner.conversation($0).indexRoot })
        for kind in [SourceKind.meeting, .file] {
            for source in try index.sources(kind: kind) where source.ref.hasPrefix(folder.path + "/") || source.root.map(roots.contains) == true {
                refs.append(source.ref)
            }
        }
        try index.setMeta("purged:" + id, "1")
        for root in roots { try index.setMeta("purged:" + root, "1") }
        try index.purge(refs: refs)
    }
    func indexFinalNote(_ url: URL, vault: URL) async {
        _ = try? await VaultIndexer(index: index, embedder: nil, extractor: FileExtractors()).update(paths: [url.path], vault: vault)
    }
}
