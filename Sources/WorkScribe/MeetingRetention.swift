import Combine
import Foundation
import WorkScribeCore

extension Notification.Name {
    static let workScribeMeetingPurged = Notification.Name("WorkScribeMeetingPurged")
}

/// Owns finalization and replays the on-disk retention journal on launch and every minute.
@MainActor
final class MeetingRetention {
    private let model: AppModel
    private let ask: AskService
    var vault: VaultStore
    private let index: IndexService?
    private let requiresIndex: Bool
    private var task: Task<Void, Never>?
    private var working = Set<String>()
    init(model: AppModel, ask: AskService, vault: VaultStore, index: IndexService?, requiresIndex: Bool = true) {
        self.model = model; self.ask = ask; self.vault = vault; self.index = index; self.requiresIndex = requiresIndex
    }
    func start() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.recover()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }
    deinit { task?.cancel() }
    func finalize(_ id: String, allowRebase: Bool = false) async throws {
        guard var meeting = model.meetingSnapshot(id), meeting.endedAt != nil,
              meeting.retention != "purged", meeting.retention != "purging" else { return }
        meeting.retention = "finalized"
        meeting.purgeAt = meeting.endedAt!.addingTimeInterval(86_400)
        meeting.attendees = MeetingWriteUp.namedVoices(meeting)
        if meeting.brief == nil {
            let lines = (meeting.notes ?? []).map { $0.enhanced ?? $0.text }
            meeting.brief = lines.isEmpty ? String(meeting.orderedSegments.prefix(2).map(\.text).joined(separator: " ").prefix(600)) : lines.prefix(3).joined(separator: " ")
        }
        let path: String
        if let document = meeting.document {
            do { path = try vault.finalizeDocument(meeting, allowRebase: allowRebase) }
            catch NoteDocument.Failure.missing where allowRebase {
                // A user-deleted file is not recreated, and cannot prolong raw-data retention.
                path = document.path
            }
        } else {
            let result = try vault.writeMeeting(meeting)
            switch result {
            case .unavailable: throw RetentionStore.RetentionError.missingNote
            case .conflicted(_, let conflict, _): path = vault.url(conflict).path
            default: path = vault.url(result.path).path
            }
        }
        meeting.vaultPath = path
        if let document=meeting.document { let inserts=try? document.finalizedInsertions(meeting:meeting); meeting.document?.insertions=inserts; meeting.document?.finalized = true; meeting.document?.path = path }
        // Journal first: a crash after marking the raw snapshot finalized must not lose its deadline.
        try RetentionStore(meetings: model.store).save(RetentionReceipt(meeting, vaultPath: path))
        try model.mutateMeeting(id) { $0 = meeting }
        model.library = model.store.list()
        model.notesChanged(id)
        if let index { await index.indexFinalNote(URL(fileURLWithPath: path), vault: vault.root) }
    }
    func done(_ id: String) async throws {
        guard !working.contains(id) else { return }
        working.insert(id); defer { working.remove(id) }
        let receipts = RetentionStore(meetings: model.store)
        if try receipts.load(id) == nil || model.meetingSnapshot(id)?.document?.finalized == false {
            // Done is an explicit disposal request. A failed optional quality pass
            // must never keep raw audio past its retention deadline.
            await NoteEnhancementScheduler.shared.finish(id, model: model)
            guard model.meetingSnapshot(id)?.endedAt != nil, !(model.busy && model.meeting?.id == id) else { throw CaptureError.message("Recording resumed; keep its raw material") }
            try await finalize(id, allowRebase: true)
        }
        if try receipts.load(id)?.state == "purged" { return }
        // Cancel writers before deletion, then reload all retained state after the disk commit.
        if var receipt = try receipts.load(id) {
            if let moved = vault.notePath(forMeeting: id) { receipt.vaultPath = vault.url(moved).path }
            receipt.conversationIDs = Array(Set((receipt.conversationIDs ?? []) + ask.conversations.filter { $0.scopeMeetingID == id }.map(\.id)))
            receipt.state = "purging"; try receipts.save(receipt)
        }
        if requiresIndex && index == nil { throw CaptureError.message("Search index unavailable; cleanup will retry on launch") }
        // Once raw data fades this writer will never revisit its managed sections.
        if let receipt = try receipts.load(id), FileManager.default.fileExists(atPath: receipt.vaultPath) {
            let url = URL(fileURLWithPath: receipt.vaultPath)
            let source = try String(contentsOf: url, encoding: .utf8)
            let clean = source.replacingOccurrences(of: #"(?m)^<!-- workscribe:(?:begin|end|frontmatter) [^\n]*-->\r?\n?"#, with: "", options: .regularExpression)
            if clean != source { try clean.write(to: url, atomically: true, encoding: .utf8) }
        }
        ask.cancelForPurge(id)
        model.cancelNoteImages(id)
        await NoteImageUnderstanding.shared.clear()
        try await index?.purgeMeeting(id, folder: model.store.directory(id), conversationIDs: receipts.load(id)?.conversationIDs ?? [])
        try receipts.purge(id, meetings: model.store, conversations: ask.store, index: nil)
        ask.reloadAfterPurge(id)
        model.library = model.store.list()
        if model.meeting?.id == id { model.meeting = try model.store.load(id); model.screenMoments = [] }
        NotificationCenter.default.post(name: .workScribeMeetingPurged, object: self, userInfo: ["meeting_id": id])
    }
    func recover() async {
        for meeting in model.store.list() where meeting.endedAt != nil && meeting.retention == nil && meeting.document == nil && !(model.busy && model.meeting?.id == meeting.id) {
            do {
                let finished = await NoteEnhancementScheduler.shared.finish(meeting.id, model: model)
                let expired = Date().timeIntervalSince(meeting.endedAt!) >= 86_400
                if finished || expired { try await finalize(meeting.id, allowRebase: expired) }
            } catch { model.message = "Couldn’t finalize saved notes: \(error.localizedDescription)" }
        }
        for meeting in model.store.list() where meeting.document?.finalized == false && meeting.endedAt != nil && !(model.busy && model.meeting?.id == meeting.id) {
            if Date() >= meeting.endedAt!.addingTimeInterval(82_800) {
                do {
                    try await finalize(meeting.id, allowRebase: true)
                    Notifier.post("Meeting note finalized", "Your edits are safe. The transcript fades in one hour.")
                } catch { model.message = "Couldn’t finalize saved notes: \(error.localizedDescription)" }
            }
        }
        for receipt in RetentionStore(meetings: model.store).list() where receipt.state == "purging" || (receipt.state != "purged" && receipt.purgeAt <= Date()) {
            if model.meetingSnapshot(receipt.id)?.endedAt == nil { continue }
            do { try await done(receipt.id) }
            catch { model.message = "Meeting cleanup will retry: \(error.localizedDescription)" }
        }
    }
}
