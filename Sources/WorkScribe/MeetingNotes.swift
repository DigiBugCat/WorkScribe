import Foundation
import WorkScribeCore

extension Notification.Name {
    /// A meeting's notes or missed topics changed (a jot, an edit, an enhancement). userInfo: "meeting_id".
    static let workScribeNotesChanged = Notification.Name("WorkScribeNotesChanged")
}

/// Shorthand notes on meetings: jots from the local API (and later the in-app editor), with live incremental
/// enhancement by the bundled model. The live meeting is edited in memory and saved; others are loaded and saved.
extension AppModel {
    enum NoteError: LocalizedError {
        case noMeeting, noNote, empty
        var errorDescription: String? {
            switch self {
            case .noMeeting: "No such meeting"
            case .noNote: "No such note"
            case .empty: "Note text is empty"
            }
        }
    }

    /// The live meeting when it is the one asked for, else the saved one.
    func meetingSnapshot(_ id: String) -> Meeting? {
        if meeting?.id == id { return meeting }
        return try? store.load(id)
    }

    @discardableResult
    func mutateMeeting(_ id: String, _ change: (inout Meeting) throws -> Void) throws -> Meeting {
        if var live = meeting, live.id == id {
            guard live.retention != "purged" && live.retention != "purging" else { throw NoteError.noMeeting }
            try change(&live)
            meeting = live
            try save()
            if let index = library.firstIndex(where: { $0.id == id }) { library[index] = live }
            return live
        }
        var saved = try store.load(id)
        guard saved.retention != "purged" && saved.retention != "purging" else { throw NoteError.noMeeting }
        try change(&saved)
        try store.save(saved)
        if let index = library.firstIndex(where: { $0.id == id }) { library[index] = saved }
        return saved
    }

    func addNote(meetingID: String, text: String, at: Double?, fromAnswer: NoteAnswerOrigin? = nil, fromMissedTopic: String? = nil) throws -> Note {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NoteError.empty }
        guard meetingSnapshot(meetingID) != nil else { throw NoteError.noMeeting }
        let live = meeting?.id == meetingID && phase == "recording"
        let when = at ?? (live ? meeting.map { Date().timeIntervalSince($0.startedAt) } : nil)
        var note = Note(text: text, createdAt: when)
        note.fromAnswer = fromAnswer
        note.enhancementState = fromAnswer == nil ? "pending" : "plain"
        try mutateMeeting(meetingID) { meeting in
            if let topic = fromMissedTopic, let missed = meeting.missedTopics?.first(where: { $0.topic == topic }) {
                note.editEnhancement(.init(topic: missed.topic, text: missed.text))
                note.excerptRefs = missed.excerptRefs
                meeting.missedTopics?.removeAll { $0.topic == topic }
            }
            meeting.notes = (meeting.notes ?? []) + [note]
        }
        notesChanged(meetingID)
        NoteEnhancementScheduler.shared.schedule(meetingID, model: self)
        return note
    }

    func editNote(meetingID: String, noteID: String, text: String) throws -> Note {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NoteError.empty }
        var edited: Note?
        try mutateMeeting(meetingID) { meeting in
            guard let index = meeting.notes?.firstIndex(where: { $0.id == noteID }) else { throw NoteError.noNote }
            meeting.notes![index].editText(text)
            edited = meeting.notes![index]
        }
        notesChanged(meetingID)
        NoteEnhancementScheduler.shared.schedule(meetingID, model: self)
        return edited!
    }

    func editNoteEnhancement(meetingID: String, noteID: String, enhanced: NoteEnhancementText) throws -> Note {
        guard !(enhanced.topic + enhanced.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NoteError.empty }
        var edited: Note?
        try mutateMeeting(meetingID) { meeting in
            guard let index = meeting.notes?.firstIndex(where: { $0.id == noteID }) else { throw NoteError.noNote }
            meeting.notes![index].editEnhancement(enhanced)
            edited = meeting.notes![index]
        }
        notesChanged(meetingID)
        return edited!
    }

    func letAIRewrite(meetingID: String, noteID: String) throws -> Note {
        var edited: Note?
        try mutateMeeting(meetingID) { meeting in
            guard let i = meeting.notes?.firstIndex(where: { $0.id == noteID }) else { throw NoteError.noNote }
            meeting.notes![i].letAIRewrite(); edited = meeting.notes![i]
        }
        notesChanged(meetingID); NoteEnhancementScheduler.shared.schedule(meetingID, model: self)
        return edited!
    }

    func notesChanged(_ meetingID: String) {
        NotificationCenter.default.post(name: .workScribeNotesChanged, object: self, userInfo: ["meeting_id": meetingID])
    }
}

/// Debounces enhancement per meeting: a few seconds after the last jot, one incremental pass over stale notes.
/// Without the bundled model (a dev build) the notes simply stay unenhanced.
@MainActor
final class NoteEnhancementScheduler {
    static let shared = NoteEnhancementScheduler()
    var enhancer: any NoteEnhancing = NoteEnhancer()
    var delay: UInt64 = 4_000_000_000
    var minimumInterval: TimeInterval = 15
    private var pending: [String: Task<Void, Never>] = [:]
    private var running: Set<String> = []
    private var finalizing: Set<String> = []
    private var dirty: Set<String> = []
    private var lastRun: [String: Date] = [:]
    /// Transcript updates are throttled to one pass per 15 seconds, with a trailing pass.
    func schedule(_ id: String, model: AppModel) {
        dirty.insert(id)
        guard !finalizing.contains(id) else { return }
        guard !model.liveAIPaused else { return }
        guard pending[id] == nil else { return }
        pending[id] = Task { [weak self, weak model] in
            guard let self else { return }
            let remaining = max(0, minimumInterval - Date().timeIntervalSince(lastRun[id] ?? .distantPast))
            try? await Task.sleep(nanoseconds: max(delay, UInt64(remaining * 1_000_000_000)))
            pending[id] = nil
            guard !Task.isCancelled, let model else { return }
            await run(id, model: model, final: false)
        }
    }
    @discardableResult func finish(_ id: String, model: AppModel) async -> Bool {
        guard finalizing.insert(id).inserted else { return false }
        defer {
            finalizing.remove(id)
            if dirty.contains(id) { schedule(id, model: model) }
        }
        let endedAt = model.meetingSnapshot(id)?.endedAt
        pending.removeValue(forKey: id)?.cancel()
        do {
            try await RecordingDeadline.wait(stall: model.stallTimeout) {
                while self.running.contains(id) {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        } catch { return false }
        guard !Task.isCancelled else { return false }
        do {
            try await RecordingDeadline.wait(stall: max(model.stallTimeout, 120), progress: { model.finalizationProgress }) {
                try await model.polishTranscript(id)
            }
        }
        catch {
            if model.meetingSnapshot(id)?.endedAt == endedAt, model.phase != "starting" {
                model.message = "Recording saved · transcript polish couldn’t finish"
            }
            // Do not present another draft based on the incomplete live transcript as final.
            return false
        }
        guard !Task.isCancelled, model.meetingSnapshot(id)?.endedAt == endedAt else { return false }
        if model.meeting?.id == id, model.phase == "finalizing" { model.message = "Finishing your notes…" }
        do {
            try await RecordingDeadline.wait(stall: model.stallTimeout) { await model.finishNoteImages(id) }
        } catch { return false }
        guard model.meetingSnapshot(id)?.endedAt == endedAt else { return false }
        pending.removeValue(forKey: id)?.cancel()
        var success = false
        do {
            try await RecordingDeadline.wait(stall: model.stallTimeout, progress: { model.finalizationProgress }) {
                success = await self.run(id, model: model, final: true)
            }
        } catch { return false }
        return success
    }
    @discardableResult private func run(_ id: String, model: AppModel, final: Bool) async -> Bool {
        guard (final || !model.liveAIPaused), !running.contains(id), let snapshot = model.meetingSnapshot(id),
              snapshot.retention != "purged", snapshot.retention != "purging" else { return false }
        let generation = model.recordingGeneration
        running.insert(id); dirty.remove(id); lastRun[id] = Date()
        try? model.mutateMeeting(id) { meeting in
            for i in (meeting.notes ?? []).indices where meeting.notes![i].isStale {
                meeting.notes![i].enhancementState = "enhancing"
            }
        }
        model.notesChanged(id)
        defer {
            try? model.mutateMeeting(id) { meeting in
                for i in (meeting.notes ?? []).indices where meeting.notes![i].enhancementState == "enhancing" {
                    meeting.notes![i].enhancementState = meeting.notes![i].isStale ? (final ? "plain" : "pending") : "done"
                }
            }
            model.notesChanged(id)
            running.remove(id)
            if dirty.contains(id) { schedule(id, model: model) }
        }
        do {
            let prepared: NoteDraft?
            if final, let native = enhancer as? NoteEnhancer {
                prepared = try await native.enhanceFinal(snapshot) { fraction in
                    await MainActor.run {
                        if model.recordingGeneration == generation, model.meeting?.id == id, model.meeting?.endedAt == snapshot.endedAt {
                            model.finalizationProgress = 0.7 + 0.18 * fraction
                        }
                    }
                }
            } else { prepared = try await enhancer.enhance(snapshot, incremental: !final, missedTopics: final) }
            guard let draft = prepared else { return true }
            guard model.recordingGeneration == generation,
                  model.meetingSnapshot(id)?.recordingSessions?.last?.id == snapshot.recordingSessions?.last?.id,
                  model.meetingSnapshot(id)?.endedAt == snapshot.endedAt else { return false }
            try Task.checkCancellation()
            try model.mutateMeeting(id) { meeting in
                let eligible = Set(draft.plan.targets.compactMap { target -> String? in
                    guard (meeting.notes ?? []).contains(where: { $0.id == target.note.id && $0.text == target.note.text && $0.revision == target.note.revision && $0.userEdited != true && $0.fromAnswer == nil }) else { return nil }
                    return target.note.id
                })
                let result = NoteEnhancement.apply(draft.output, plan: draft.plan, to: meeting.notes ?? [])
                meeting.notes = result.notes
                for i in (meeting.notes ?? []).indices where eligible.contains(meeting.notes![i].id) {
                    // Matching is independent of whether the model emitted a usable bullet.
                    meeting.notes![i].excerptRefs = draft.plan.chunkRefs[meeting.notes![i].id] ?? []
                    var trace = meeting.notes![i].trace ?? AITrace()
                    trace.sources = draft.sceneSources[meeting.notes![i].id]
                    trace.model = draft.model; trace.location = draft.location ?? (draft.model == nil ? nil : "On this Mac")
                    trace.durationMs = draft.durationMs
                    let kept = trace.steps.filter { $0.title == "Kept: no new facts" }
                    let wrote = meeting.notes![i].enhancedFrom == meeting.notes![i].text
                    let quoted = draft.model?.hasPrefix("Transcript excerpts") == true
                    trace.steps = [TraceStep("Matched transcript", detail: "\(draft.plan.chunkRefs[meeting.notes![i].id]?.count ?? 0) excerpts"),
                                   TraceStep(wrote ? (quoted ? "Quoted transcript" : "Wrote AI line") : "No usable AI line", detail: draft.model ?? "Model not reported")] + kept
                    meeting.notes![i].trace = trace
                }
                if final {
                    for i in (meeting.notes ?? []).indices where meeting.notes![i].userEdited != true && meeting.notes![i].imageEvidence.isEmpty && (meeting.notes![i].excerptRefs ?? []).isEmpty && draft.sceneSources[meeting.notes![i].id]?.isEmpty != false {
                        meeting.notes![i].enhanced = nil; meeting.notes![i].enhancementState = "plain"
                    }
                }
                if let missed = result.missed { meeting.missedTopics = missed }
                if final { meeting.actionItems = NoteOutput.actions(draft.output, plan: draft.plan) }
            }
            model.notesChanged(id)
            if snapshot.retention == "finalized" { _ = VaultHookup.shared?.write(meetingID: id) }
            return true
        } catch {
            guard model.recordingGeneration == generation else { return false }
            try? model.mutateMeeting(id) { meeting in
                for i in (meeting.notes ?? []).indices where meeting.notes![i].userEdited != true {
                    meeting.notes![i].enhancementState = "paused"
                }
            }
            model.message = "AI lines paused · your notes are saving"
            return false
        }
    }
}
