import CoreServices
import Foundation

/// Watches a vault with FSEvents and reports debounced batches of changed note paths, or that a full rescan is needed.
///
/// Checkpointing: each batch carries the last event id. Persist it once the batch is indexed and pass it back as
/// `since` on the next launch; FSEvents then replays what changed while WorkScribe wasn't running. A checkpoint from
/// another volume (its event-database UUID differs), dropped or coalesced events, a moved root or wrapped ids all
/// ask for a rescan instead, as Apple's FSEvents guide requires.
public final class VaultWatcher: @unchecked Sendable {
    public enum Change: Equatable, Sendable {
        case paths([String], checkpoint: Checkpoint)
        case rescan(reason: String, checkpoint: Checkpoint)
        public var checkpoint: Checkpoint {
            switch self { case .paths(_, let c), .rescan(_, let c): c }
        }
    }

    /// `<event-database UUID>:<event id>`.
    public struct Checkpoint: Equatable, Sendable, CustomStringConvertible {
        public var device: String
        public var eventID: UInt64
        public init(device: String, eventID: UInt64) { self.device = device; self.eventID = eventID }
        public init?(_ text: String) {
            let parts = text.split(separator: ":")
            guard parts.count == 2, let id = UInt64(parts[1]) else { return nil }
            device = String(parts[0]); eventID = id
        }
        public var description: String { "\(device):\(eventID)" }
    }

    public let root: URL
    public let debounce: TimeInterval
    let handler: @Sendable (Change) -> Void
    private let queue = DispatchQueue(label: "WorkScribe vault watcher")
    private var stream: FSEventStreamRef?
    private var snapshotTimer: DispatchSourceTimer?
    private var snapshot: [String: String] = [:]
    private var snapshotRevision: UInt64 = 0
    private var pending = Set<String>()
    private var pendingRescan: String?
    private var lastEventID: UInt64 = 0
    private var flush: DispatchWorkItem?
    let device: String

    public init(root: URL, debounce: TimeInterval = 1.5, handler: @escaping @Sendable (Change) -> Void) {
        self.root = FileIdentity.url(root); self.debounce = debounce; self.handler = handler
        device = Self.deviceUUID(for: root) ?? "unknown"
    }

    /// The UUID of the FSEvents database for the volume holding `url`.
    public static func deviceUUID(for url: URL) -> String? {
        var info = stat()
        guard stat(url.path, &info) == 0, let uuid = FSEventsCopyUUIDForDevice(info.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// Starts watching. With a matching checkpoint, events since then are replayed; otherwise the first batch is a
    /// rescan (`reason` says why) so the caller indexes everything once.
    public func start(since checkpoint: Checkpoint?) {
        queue.sync {
            guard stream == nil, snapshotTimer == nil else { return }
            // The daemon may be unavailable (including restricted macOS sessions).
            // Keep edits working with metadata-only snapshots; never pretend these are replayable FSEvent IDs.
            if device == "unknown" || FSEventsGetCurrentEventId() == 0 {
                startSnapshots()
                return
            }
            var since = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
            if let checkpoint, checkpoint.device == device, checkpoint.eventID > 0 {
                since = checkpoint.eventID
                lastEventID = checkpoint.eventID
            } else {
                lastEventID = FSEventsGetCurrentEventId()
                pendingRescan = checkpoint == nil ? "first watch" : "checkpoint from another volume"
                schedule()
            }
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                                 | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
                guard let info else { return }
                let watcher = Unmanaged<VaultWatcher>.fromOpaque(info).takeUnretainedValue()
                let list = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String]) ?? []
                watcher.receive(Array(list.prefix(count)), flags: Array(UnsafeBufferPointer(start: flags, count: count)),
                                ids: Array(UnsafeBufferPointer(start: ids, count: count)))
            }
            guard let created = FSEventStreamCreate(nil, callback, &context, [root.standardizedFileURL.path] as CFArray, since, 0.3, flags) else {
                startSnapshots(); return
            }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created); FSEventStreamRelease(created)
                startSnapshots(); return
            }
            stream = created
        }
    }

    public func stop() {
        queue.sync {
            flush?.cancel(); flush = nil
            snapshotTimer?.cancel(); snapshotTimer = nil
            guard let stream else { return }
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    deinit { stop() }

    private func fileSnapshot() -> [String: String] {
        var result: [String: String] = [:]
        for url in VaultRules.walk(root) + VaultRules.images(root) {
            if let info = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey]) {
                result[url.path] = "\(info.contentModificationDate?.timeIntervalSince1970 ?? 0):\(info.fileSize ?? 0):\(String(describing: info.fileResourceIdentifier))"
            }
        }
        return result
    }

    private func startSnapshots() {
        snapshot = fileSnapshot(); snapshotRevision = 1
        handler(.rescan(reason: "FSEvents unavailable; checking file metadata", checkpoint: .init(device: "snapshot", eventID: snapshotRevision)))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let next = fileSnapshot()
            let changed = Set(snapshot.keys).union(next.keys).filter { self.snapshot[$0] != next[$0] }.sorted()
            snapshot = next
            guard !changed.isEmpty else { return }
            snapshotRevision += 1
            handler(.paths(changed, checkpoint: .init(device: "snapshot", eventID: snapshotRevision)))
        }
        snapshotTimer = timer; timer.resume()
    }

    /// Why a batch of flags needs a full rescan, or nil.
    public static func rescanReason(_ flags: FSEventStreamEventFlags) -> String? {
        let value = Int(flags)
        if value & kFSEventStreamEventFlagMustScanSubDirs != 0 { return "events were coalesced" }
        if value & (kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 { return "events were dropped" }
        if value & kFSEventStreamEventFlagRootChanged != 0 { return "the vault folder moved" }
        if value & kFSEventStreamEventFlagEventIdsWrapped != 0 { return "event ids wrapped" }
        if value & (kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount) != 0 { return "a volume was mounted or unmounted" }
        return nil
    }

    /// FSEvents reports real paths (`/private/var/…` for `/var/…`).
    lazy var canonicalRoot: String = {
        guard let resolved = realpath(root.path, nil) else { return root.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }()

    /// The event path expressed under `root`, when it is a note the index cares about.
    public func relevantPath(_ path: String) -> String? {
        let path = FileIdentity.path(path)
        for base in [root.path, canonicalRoot] where path.hasPrefix(base + "/") {
            let relative = String(path.dropFirst(base.count + 1))
            return VaultRules.isNote(relative) ? root.appendingPathComponent(relative).path : nil
        }
        return nil
    }

    func receive(_ paths: [String], flags: [FSEventStreamEventFlags], ids: [FSEventStreamEventId]) {
        for (index, path) in paths.enumerated() {
            let flag = flags[index]
            if ids[index] > lastEventID { lastEventID = ids[index] }
            if Int(flag) & kFSEventStreamEventFlagHistoryDone != 0 { continue }
            if let reason = Self.rescanReason(flag) { pendingRescan = reason; continue }
            if let path = relevantPath(path) { pending.insert(path) }
        }
        if pendingRescan != nil || !pending.isEmpty { schedule() }
    }

    private func schedule() {
        flush?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.deliver() }
        flush = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func deliver() {
        let checkpoint = Checkpoint(device: device, eventID: lastEventID)
        if let reason = pendingRescan {
            pendingRescan = nil; pending.removeAll()
            handler(.rescan(reason: reason, checkpoint: checkpoint))
        } else if !pending.isEmpty {
            let paths = pending.sorted(); pending.removeAll()
            handler(.paths(paths, checkpoint: checkpoint))
        }
    }
}
