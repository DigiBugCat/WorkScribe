import Foundation

/// The durable deletion journal contains metadata only, never transcript/evidence/answer text.
/// Persist `purging` before touching files; replaying it after a crash is safe.
public struct RetentionReceipt: Codable, Identifiable {
    public var id: String
    public var title: String
    public var startedAt: Date
    public var endedAt: Date
    public var purgeAt: Date
    public var vaultPath: String
    public var state: String
    public var conversationIDs: [String]?
    public init(_ meeting: Meeting, vaultPath: String) {
        id = meeting.id; title = meeting.title; startedAt = meeting.startedAt
        endedAt = meeting.endedAt ?? meeting.startedAt
        purgeAt = meeting.purgeAt ?? endedAt.addingTimeInterval(86_400)
        self.vaultPath = vaultPath; state = "finalized"
    }
    public var meeting: Meeting {
        var m = Meeting(title: title); m.id = id; m.startedAt = startedAt; m.endedAt = endedAt
        m.status = "complete"; m.retention = state; m.purgeAt = purgeAt; m.vaultPath = vaultPath
        return m
    }
}

public struct RetentionStore {
    public let root: URL
    public init(meetings: MeetingStore) { root = meetings.root.appendingPathComponent(".retention", isDirectory: true) }
    public func load(_ id: String) throws -> RetentionReceipt? {
        guard UUID(uuidString: id) != nil else { throw MeetingStore.StoreError.invalidID }
        let url = root.appendingPathComponent(id + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RetentionReceipt.self, from: Data(contentsOf: url))
    }
    public func list() -> [RetentionReceipt] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { try? load($0.deletingPathExtension().lastPathComponent) }
    }
    public func save(_ receipt: RetentionReceipt) throws {
        guard UUID(uuidString: receipt.id) != nil else { throw MeetingStore.StoreError.invalidID }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let url = root.appendingPathComponent(receipt.id + ".json")
        try encoder.encode(receipt).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    /// All transcript citations are stripped across conversations, including cross-meeting questions.
    /// Entire meeting-scoped answers are removed unless already copied into the vault note.
    public func purge(_ id: String, meetings: MeetingStore, conversations: ConversationStore, index: SearchIndex?) throws {
        ScreenFiles.mutationLock.lock(); defer { ScreenFiles.mutationLock.unlock() }
        guard var receipt = try load(id) else { throw MeetingStore.StoreError.invalidID }
        if receipt.state == "purged" { return }
        let conversationsToDelete = Set((receipt.conversationIDs ?? []) + conversations.list().filter { $0.scopeMeetingID == id }.map(\.id))
        receipt.conversationIDs = Array(conversationsToDelete)
        receipt.state = "purging"; try save(receipt)
        let folder = try meetings.directory(id)
        var refs = [id]
        let ownerRoots = Set([AttachmentOwner.meeting(id).indexRoot] + conversationsToDelete.map { AttachmentOwner.conversation($0).indexRoot })
        if let index {
            try index.setMeta("purged:" + id, "1")
            for root in ownerRoots { try index.setMeta("purged:" + root, "1") }
            for source in try [SourceKind.meeting, .file].flatMap({ try index.sources(kind: $0) }) where source.ref.hasPrefix(folder.path + "/") || source.root.map(ownerRoots.contains) == true { refs.append(source.ref) }
            try index.purge(refs: refs)
        }
        for var conversation in conversations.list() {
            if conversationsToDelete.contains(conversation.id) {
                // Nothing from the raw Q&A survives outside text explicitly inserted into notes.
                try FileManager.default.removeItem(at: conversations.directory(conversation.id))
            } else {
                var changed = false
                for i in conversation.messages.indices {
                    let old = conversation.messages[i].citations.count
                    conversation.messages[i].citations.removeAll { $0.moment.ref == id || $0.moment.ref.hasPrefix(folder.path + "/") }
                    if old != conversation.messages[i].citations.count || conversation.messages[i].trace?.sources?.contains(where: { $0.link.contains(id) || $0.link.contains(folder.path) }) == true {
                        // The answer itself can paraphrase raw transcript; discard it too.
                        conversation.messages[i].text = "Meeting source deleted."
                        conversation.messages[i].trace = nil
                        changed = true
                    }
                }
                if changed { try conversations.save(conversation) }
            }
        }
        for id in conversationsToDelete {
            let directory = try conversations.directory(id)
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        }
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        receipt.state = "purged"; try save(receipt)
    }
    public enum RetentionError: Error { case missingNote }
}
