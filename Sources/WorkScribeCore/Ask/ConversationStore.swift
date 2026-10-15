import Foundation

/// Conversations as JSON, one folder each (`<root>/<id>/conversation.json`, attachments in `<root>/<id>/attachments/`),
/// under Application Support next to the meetings.
public struct ConversationStore: Sendable {
    public let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? ProcessInfo.processInfo.environment["WORKSCRIBE_CONVERSATIONS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WorkScribe/Conversations")
    }

    public func directory(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw MeetingStore.StoreError.invalidID }
        return root.appendingPathComponent(id, isDirectory: true)
    }

    public func attachments(_ id: String) throws -> Attachments {
        Attachments(folder: try directory(id).appendingPathComponent("attachments", isDirectory: true))
    }

    public func save(_ conversation: Conversation) throws {
        let folder = try directory(conversation.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("conversation.json")
        try Self.encoder.encode(conversation).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public func load(_ id: String) throws -> Conversation {
        try Self.decoder.decode(Conversation.self, from: Data(contentsOf: directory(id).appendingPathComponent("conversation.json")))
    }

    /// Newest activity first.
    public func list() -> [Conversation] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { try? load($0.lastPathComponent) }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Moves the folder (and its attachments) to the Trash.
    public func trash(_ id: String) throws {
        try FileManager.default.trashItem(at: directory(id), resultingItemURL: nil)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
