import Foundation
import WorkScribeCore

/// Live transcript chunks, interactive queries, and yielding background indexing share admission.
/// Only recording pressure blocks embeddings; recording itself does not.
actor IndexService {
    let index: SearchIndex
    private(set) var embedder: CoreMLEmbedder?
    let store: MeetingStore
    let admission = IndexAdmission()
    private var liveTask: Task<Void, Never>?
    private var pendingLive: Meeting?
    private var liveFingerprint: String?
    private var running: Task<Void, Never>?
    private var pendingMeetings = false
    private var pendingFolders = false
    /// Screen reading outside meetings (`ScreenDay`), when the app keeps any.
    private var screenDays: ScreenDayStore?
    private var pendingScreen = false
    private var lastScreenSync = Date.distantPast
    private var screenDelay: Task<Void, Never>?
    private(set) var lastScreenReport: IndexReport?
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
        meetingsChanged()
        foldersChanged()
    }

    func setPressure(_ value: RecordingPressure) async { await admission.setPressure(value) }

    var queryEmbedder: (any Embedder)? {
        embedder.map { AdmittedEmbedder($0, admission: admission, priority: .query) }
    }
    private var backlogEmbedder: (any Embedder)? {
        embedder.map { AdmittedEmbedder($0, admission: admission, priority: .backlog) }
    }

    /// `segments` are finalized ASR turns; partial hypotheses live in a separate field.
    /// Coalesce snapshots while a call runs and reuse unchanged chunk vectors.
    func liveChanged(_ meeting: Meeting) {
        guard ProcessInfo.processInfo.environment["WORKSCRIBE_INDEX_DISABLED"] != "1",
              !["purged", "purging"].contains(meeting.retention ?? "") else { return }
        do { try index.saveLines(meeting) }
        catch { status = "Line persistence: \(error.localizedDescription)"; return }
        let fingerprint = MeetingSource.fingerprint(meeting) + ":voice:\(meeting.voiceRevision ?? 0)"
        guard fingerprint != liveFingerprint else { return }
        do { _ = try index.apply(MeetingSource.revision(meeting)) }
        catch { status = "Live indexing: \(error.localizedDescription)"; return }
        liveFingerprint = fingerprint
        pendingLive = meeting
        guard liveTask == nil else { return }
        liveTask = Task { await applyPendingSpeech() }
    }
    private func applyPendingSpeech() async {
        while let meeting = pendingLive, !Task.isCancelled {
            pendingLive = nil
            let embedder = self.embedder.map { AdmittedEmbedder($0, admission: admission, priority: .live) }
            do {
                if let embedder { try index.adopt(modelID: embedder.modelID) }
                if let embedder { try await index.embedMissing(SourceID(.meeting, meeting.id), using: embedder) }
            } catch { status = "Live indexing: \(error.localizedDescription)" }
        }
        liveTask = nil
    }

    /// Enter the actor before reading so queued source revisions precede a note selection.
    func evidenceIndex() -> SearchIndex { index }

    // MARK: Indexing

    func meetingsChanged() { pendingMeetings = true; kick() }
    func foldersChanged() { pendingFolders = true; kick() }

    func useScreenDays(_ store: ScreenDayStore) { screenDays = store }
    /// The day's journal changed. Reading goes on all day, so the index follows at most every two minutes;
    /// `now` (a day was deleted, the app just launched) does not wait.
    func screenChanged(now: Bool = false) {
        guard screenDays != nil else { return }
        let wait = now ? 0 : 120 - Date().timeIntervalSince(lastScreenSync)
        if wait <= 0 { screenDelay?.cancel(); screenDelay = nil; pendingScreen = true; kick(); return }
        guard screenDelay == nil else { return }
        screenDelay = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.screenDue()
        }
    }
    private func screenDue() { screenDelay = nil; pendingScreen = true; kick() }

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
        guard running == nil, ProcessInfo.processInfo.environment["WORKSCRIBE_INDEX_DISABLED"] != "1" else { return }
        running = Task.detached(priority: .utility) { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        let gate: @Sendable () async -> Void = { await Task.yield() }
        while pendingMeetings || pendingFolders || pendingVault != nil || pendingScreen {
            if pendingScreen {
                pendingScreen = false; lastScreenSync = Date()
                if let screenDays {
                    status = "Indexing screen history…"
                    lastScreenReport = try? await ScreenDayIndexer(index: index, embedder: backlogEmbedder, gate: gate).sync(store: screenDays)
                }
            }
            if pendingMeetings {
                pendingMeetings = false
                status = "Indexing meetings…"
                lastReport.meetings = try? await MeetingIndexer(index: index, embedder: backlogEmbedder, gate: gate).sync(store: store)
            }
            if pendingFolders {
                pendingFolders = false
                status = "Indexing folders…"
                lastReport.folders = try? await FolderIndexer(index: index, embedder: backlogEmbedder, extractor: FileExtractors(), gate: gate).sync()
            }
            if let work = pendingVault, let root = vaultRoot {
                pendingVault = nil
                status = "Indexing notes…"
                let indexer = VaultIndexer(index: index, embedder: backlogEmbedder, extractor: FileExtractors(), gate: gate)
                let report: IndexReport? = if let paths = work.paths { try? await indexer.update(paths: Array(paths), vault: root) }
                    else { try? await indexer.sync(vault: root) }
                lastVaultReport = report
                if report != nil, let checkpoint = work.checkpoint { try? index.setMeta(Self.checkpointKey(root), checkpoint.description) }
            } else { pendingVault = nil }
        }
        index.invalidate()   // vectors reload lazily on the next meaning search
        status = "Search index up to date"
        running = nil
    }

    // MARK: Search

    func shutdown() async {
        running?.cancel()
        pendingMeetings = false; pendingFolders = false; pendingVault = nil
        pendingScreen = false; screenDelay?.cancel(); screenDelay = nil
        await running?.value
        await finishLive()
    }

    func finishLive() async {
        pendingLive = nil
        liveTask?.cancel()
        await liveTask?.value
        liveTask = nil
        liveFingerprint = nil
    }

    func search(_ request: SearchRequest) async throws -> SearchResults {
        var vector: [Float]?
        if let embedder = queryEmbedder, index.vectorModel == embedder.modelID, !request.text.trimmingCharacters(in: .whitespaces).isEmpty {
            vector = try? await embedder.text(request.text, role: .query)
        }
        return try index.search(request, queryVector: vector, queryModelID: embedder?.modelID)
    }
}

extension IndexService {
    /// The meeting's transcript, the files in its folder, and what was attached to it or to `conversationIDs`.
    func purgeMeeting(_ id: String, folder: URL, conversationIDs: [String] = []) throws {
        let roots = Set([AttachmentOwner.meeting(id).indexRoot] + conversationIDs.map { AttachmentOwner.conversation($0).indexRoot })
        try index.purge(meeting: id, folder: folder.path, roots: roots)
    }
    func indexFinalNote(_ url: URL, vault: URL) async {
        guard ProcessInfo.processInfo.environment["WORKSCRIBE_INDEX_DISABLED"] != "1" else { return }
        _ = try? await VaultIndexer(index: index, embedder: backlogEmbedder, extractor: FileExtractors()).update(paths: [url.path], vault: vault)
    }
}
