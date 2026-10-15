import Foundation
import WorkScribeCore

/// Synthetic recording fixture through the same finalizer, journal, and deletion path as Done.
@MainActor enum PurgeVerification {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workscribe-purge-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root.appendingPathComponent("Meetings"))
        var meeting = Meeting(title: "Purge verification")
        meeting.status = "complete"; meeting.endedAt = Date()
        meeting.segments = [Segment(source: "microphone", speaker: "mic:1", start: 0, end: 1, text: "Unique raw fixture text")]
        meeting.notes = [Note(text: "Keep this note", createdAt: 1)]
        try store.save(meeting)
        let folder = try store.directory(meeting.id)
        for name in ["microphone.wav", "screen.mov", "screen.json", "orphan.tmp"] {
            try Data("Unique raw fixture text".utf8).write(to: folder.appendingPathComponent(name))
        }
        let model = AppModel(store: store)
        let ask = AskService(model: model, store: ConversationStore(root: root.appendingPathComponent("Conversations")), generator: nil)
        let vault = VaultStore(root: root.appendingPathComponent("Notes"), stateDirectory: root.appendingPathComponent("Vault"))
        let search = try SearchIndex(url: root.appendingPathComponent("index.sqlite"))
        let index = IndexService(index: search, store: store, embedder: nil)
        _ = try await MeetingIndexer(index: search, embedder: nil).sync(store: store)
        let retention = MeetingRetention(model: model, ask: ask, vault: vault, index: index)
        try await retention.finalize(meeting.id)
        try await retention.done(meeting.id)
        try await retention.done(meeting.id)
        let saved = try store.load(meeting.id)
        guard saved.retention == "purged", saved.segments.isEmpty,
              !FileManager.default.fileExists(atPath: folder.path),
              try search.source(ref: meeting.id) == nil, try search.vectorStats().count == 0,
              let path = saved.vaultPath else { throw CaptureError.message("Purge verification failed") }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        guard text.contains("Keep this note"), !text.contains("workscribe://"), !text.contains("^e1") else {
            throw CaptureError.message("Final vault note is invalid")
        }
        print("Purge verified: final note retained; raw folder, index and vectors removed; replay is idempotent.")
    }
}
