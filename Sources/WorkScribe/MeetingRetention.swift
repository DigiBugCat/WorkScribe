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
    /// Tests only: runs each time the index has been purged for a meeting, standing in for whatever else the
    /// main actor did while that was awaited.
    var afterIndexPass: (() -> Void)?
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
        // The journal on disk is the authority, not the copy of the meeting in memory: a purge that has been
        // journalled is never turned back into "finalized" (formal/tla/Retention.tla, T4).
        if let state = try RetentionStore(meetings: model.store).load(id)?.state, state == "purging" || state == "purged" { return }
        guard var meeting = model.meetingSnapshot(id), meeting.endedAt != nil,
              meeting.retention != "purged", meeting.retention != "purging" else { return }
        meeting.retention = "finalized"
        meeting.purgeAt = meeting.endedAt!.addingTimeInterval(86_400)
        meeting.attendees = MeetingWriteUp.namedVoices(meeting)
        // The brief comes only from the final pass (`BriefPolicy`). Note lines glued together, or
        // the first seconds of transcript, are not a summary; no brief is better than that.
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
        // Deleting needs the index: say so before the journal says "purging", or the meeting would show as
        // purged for the whole session with its transcript still on disk (T5).
        if requiresIndex && index == nil { throw CaptureError.message("Search isn’t available, so nothing was deleted. The transcript still fades at its deadline once search is back.") }
        let known = try receipts.load(id)
        // A purge already journalled is replayed as it stands: nothing is finalized again for it, whatever the
        // copy in memory says by now, or an interrupted purge would be turned away every minute (T5).
        if known?.state != "purging", known == nil || Self.predates(known, lastStopOf: model.meetingSnapshot(id)) || model.meetingSnapshot(id)?.document?.finalized == false {
            // Done is an explicit disposal request. A failed optional quality pass
            // must never keep transcript evidence past its retention deadline.
            await NoteEnhancementScheduler.shared.finish(id, model: model)
            guard model.meetingSnapshot(id)?.endedAt != nil, !(model.busy && model.meeting?.id == id) else { throw CaptureError.message("Recording resumed; keep its raw material") }
            try await finalize(id, allowRebase: true)
            // Resumed while the note was being written: it is recording again, and nothing of it is purged (T6).
            guard let latest = model.meetingSnapshot(id), latest.endedAt != nil, !(model.busy && model.meeting?.id == id) else { throw CaptureError.message("Recording resumed; keep its raw material") }
            // Resumed and stopped again, or the finalize undone, while the note was being indexed: what was
            // just written is no longer the meeting's last word, so look again at what sent us here. The next
            // round finalizes again first (T7).
            guard !Self.predates(try receipts.load(id), lastStopOf: latest), latest.document?.finalized != false else {
                throw CaptureError.message("The meeting changed while its note was being finalized; cleanup will try again")
            }
        }
        if try receipts.load(id)?.state == "purged" { return }
        // Cancel writers before deletion, then reload all retained state after the disk commit.
        if var receipt = try receipts.load(id) {
            if let moved = vault.notePath(forMeeting: id) { receipt.vaultPath = vault.url(moved).path }
            receipt.conversationIDs = Array(Set((receipt.conversationIDs ?? []) + ask.conversations.filter { $0.scopeMeetingID == id }.map(\.id)))
            receipt.state = "purging"; try receipts.save(receipt)
        }
        // Once raw data fades this writer will never revisit its managed sections.
        // Compared and exchanged like every other write to the note: read, clean and write with nothing in between
        // replaced whatever Obsidian had saved since the read (formal/tla/VaultNote.tla, `NoLostSave`). A note
        // that cannot be read as text no longer stops the purge.
        if let receipt = try receipts.load(id), FileManager.default.fileExists(atPath: receipt.vaultPath) {
            vault.removeMarkers(at: URL(fileURLWithPath: receipt.vaultPath))
        }
        ask.cancelForPurge(id)
        model.cancelNoteImages(id)
        await NoteImageUnderstanding.shared.clear()
        // A question asked from this meeting's page while its index rows are being deleted (that is an await)
        // starts a conversation scoped to it. `receipts.purge` below deletes that conversation's files with all
        // the others, so its rows must go first: the index is purged again until a pass finds no conversation it
        // had not been told about. Nothing suspends between that last look and the deletion
        // (formal/tla/IndexPurge.tla, `Gone`).
        var told: Set<String>?
        while true {
            let scoped = Set((try receipts.load(id)?.conversationIDs ?? []) + ask.conversations.filter { $0.scopeMeetingID == id }.map(\.id))
            if let told, scoped.isSubset(of: told) { break }
            if var receipt = try receipts.load(id), Set(receipt.conversationIDs ?? []) != scoped {
                receipt.conversationIDs = Array(scoped); try receipts.save(receipt)
            }
            ask.cancelForPurge(id)
            try await index?.purgeMeeting(id, folder: model.store.directory(id), conversationIDs: Array(scoped))
            told = scoped
            afterIndexPass?()
        }
        try receipts.purge(id, meetings: model.store, conversations: ask.store, index: nil)
        ask.reloadAfterPurge(id)
        model.library = model.store.list()
        if model.meeting?.id == id { model.meeting = try model.store.load(id); model.screenMoments = [] }
        NotificationCenter.default.post(name: .workScribeMeetingPurged, object: self, userInfo: ["meeting_id": id])
    }
    /// A receipt written before the meeting's last stop. That happens when a meeting was resumed and then ended
    /// without being finalized (the app died): the receipt's deadline and its note are the first session's (T7).
    static func predates(_ receipt: RetentionReceipt?, lastStopOf meeting: Meeting?) -> Bool {
        guard let receipt, receipt.state == "finalized", let ended = meeting?.endedAt else { return false }
        return ended.timeIntervalSince(receipt.endedAt) > 1      // receipts keep whole seconds
    }
    func recover() async {
        // `retention == "live"` with an end and no document is a meeting that was resumed and then ended without
        // finalizing; nothing else would ever finalize or purge it (T5).
        for meeting in model.store.list() where meeting.endedAt != nil && (meeting.retention == nil || meeting.retention == "live") && meeting.document == nil && !(model.busy && model.meeting?.id == meeting.id) {
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
            // Only a meeting that can be read and has no end is still recording. One that cannot be read at all
            // (moved to the Trash, damaged) has no claim to outlive its deadline (T5).
            if let snapshot = model.meetingSnapshot(receipt.id), snapshot.endedAt == nil { continue }
            // Not this session's deadline: the loops above finalize it again and write a current one. Judged by
            // the copy on disk, as those loops are: a meeting that can no longer be read there must not be held
            // back for ever by the copy still in memory (T5).
            if Self.predates(receipt, lastStopOf: try? model.store.load(receipt.id)) { continue }
            do { try await done(receipt.id) }
            catch { model.message = "Meeting cleanup will retry: \(error.localizedDescription)" }
        }
    }
}
