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
            try lineIndex?.saveLines(live)
            meeting = live
            try save()
            if let index = library.firstIndex(where: { $0.id == id }) { library[index] = live }
            return live
        }
        var saved = try store.load(id)
        guard saved.retention != "purged" && saved.retention != "purging" else { throw NoteError.noMeeting }
        try change(&saved)
        try lineIndex?.saveLines(saved)
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
        note.line.state = fromAnswer == nil ? .listening : .quiet
        try mutateMeeting(meetingID) { meeting in
            if let topic = fromMissedTopic, let missed = meeting.missedTopics?.first(where: { $0.topic == topic }) {
                note.editEnhancement(.init(topic: missed.topic, text: missed.text))
                note.line.evidence = missed.excerptRefs
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
            meeting.notes![index].editText(text, at: meeting.status == "recording" ? Date().timeIntervalSince(meeting.startedAt) : nil)
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

/// Coalesces changed inputs per meeting and publishes one completed line at a time.
/// Without the bundled model (a dev build) the notes simply stay unenhanced.
@MainActor
final class NoteEnhancementScheduler {
    static let shared = NoteEnhancementScheduler()
    var enhancer: any Enriching = Enrich()
    private var waits: [String: Int] = [:]
    var delay: UInt64 = UInt64(CurrentNoteEngine.debounceSeconds * 1e9)
    var minimumInterval: TimeInterval = CurrentNoteEngine.throttleSeconds
    private var pending: [String: Task<Void, Never>] = [:]
    private var running: Set<String> = []
    private var finalizing: Set<String> = []
    private var draining: Set<String> = []
    private var dirty: Set<String> = []
    private var lastRun: [String: Date] = [:]
    private var inputs: [String: String] = [:]
    /// The live pass in flight; Stop drains it before settling.
    private var live: [String: Task<Void, Never>] = [:]
    /// Ticks on every model call of a final pass: proof of progress for the stall watchdog,
    /// whichever meeting is on screen.
    private var synthesis: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var heartbeat: [String: Double] = [:]
    /// What the last final pass could not do, in plain words (nil when it did everything).
    private(set) var warnings: [String: String] = [:]
    /// Finalized speech and jot changes wake selection; unchanged inputs do no work.
    func schedule(_ id: String, model: AppModel) {
        guard let snapshot = model.meetingSnapshot(id), !model.liveAIPaused else { return }
        let input = Chunker.hash(snapshot.segments.map { $0.id + $0.text }.joined(separator: "|") + "|" + (snapshot.notes ?? []).map { $0.id + $0.text + String($0.queryRevision) + String($0.line.owned == true) + $0.imageEvidence }.joined(separator: "|"))
        guard inputs[id] != input else { return }
        inputs[id] = input
        synthesis.removeValue(forKey: id)?.task.cancel()
        dirty.insert(id)
        guard !finalizing.contains(id), !draining.contains(id) else { return }
        guard !model.liveAIPaused else { return }
        guard !running.contains(id), pending[id] == nil else { return }
        let task = Task { [weak self, weak model] in
            guard let self, let model else { return }
            live[id] = pending.removeValue(forKey: id)
            defer { live[id] = nil }
            guard !Task.isCancelled else { return }
            await run(id, model: model, final: false)
        }
        pending[id] = task
    }
    func cancelSynthesis() {
        for job in synthesis.values { job.task.cancel() }
        synthesis.removeAll()
    }
    /// Recognition needs the GPU back (the Mac got busy, or Stop is draining the recognizer): cut the
    /// live pass short. Its finished lines are kept and the rest run when AI lines resume.
    func yieldLive(_ id: String) {
        cancelSynthesis()
        pending.removeValue(forKey: id)?.cancel()
        if let task = live[id] { task.cancel(); dirty.insert(id) }; inputs[id] = nil
    }
    /// Stop admits no new live work while recognition drains, but keeps the current line.
    func beginStop(_ id: String) {
        draining.insert(id)
        cancelSynthesis()
        pending.removeValue(forKey: id)?.cancel()
    }
    @discardableResult func finish(_ id: String, model: AppModel) async -> Bool {
        guard finalizing.insert(id).inserted else { return false }
        draining.remove(id)
        defer {
            finalizing.remove(id)
            if dirty.contains(id) { inputs[id] = nil; schedule(id, model: model) }
        }
        let endedAt = model.meetingSnapshot(id)?.endedAt
        warnings[id] = nil
        pending.removeValue(forKey: id)?.cancel()
        // Drain the active line instead of cancelling a nearly finished answer and regenerating it.
        if let task = live[id] { await task.value }
        guard !Task.isCancelled else { return false }
        guard !Task.isCancelled, model.meetingSnapshot(id)?.endedAt == endedAt else { return false }
        if model.meeting?.id == id, model.phase == "finalizing" { model.message = "Finishing your notes…" }
        do {
            try await RecordingDeadline.wait(stall: model.stallTimeout) { await model.finishNoteImages(id) }
        } catch { return false }
        guard model.meetingSnapshot(id)?.endedAt == endedAt else { return false }
        pending.removeValue(forKey: id)?.cancel()
        var success = false
        heartbeat[id] = 0
        do {
            try await RecordingDeadline.wait(stall: model.stallTimeout, progress: { (self.heartbeat[id] ?? 0) + model.finalizationProgress }) {
                success = await self.run(id, model: model, final: true)
            }
        } catch {
            warnings[id] = "the local model stopped responding while writing the final lines"
            return false
        }
        if !success, warnings[id] == nil { warnings[id] = "the final lines couldn’t be written" }
        guard success, model.meetingSnapshot(id)?.endedAt == endedAt else { return success }
        if let native = enhancer as? Enrich, let snapshot = model.meetingSnapshot(id) {
            synthesis[id]?.task.cancel()
            let jobID = UUID()
            let job = Task { [weak self, weak model] in
                guard let self, let model else { return }
                defer { if synthesis[id]?.id == jobID { synthesis[id] = nil } }
                let extra = try? await native.synthesis.afterStop(snapshot)
                guard !Task.isCancelled, model.meetingSnapshot(id)?.endedAt == endedAt else { return }
                if let extra {
                    try? model.mutateMeeting(id) { meeting in
                        meeting.missedTopics = extra.topics
                        meeting.actionItems = extra.actions
                    }
                }
                let brief = await native.synthesis.brief(model.meetingSnapshot(id) ?? snapshot)
                guard !Task.isCancelled, model.meetingSnapshot(id)?.endedAt == endedAt else { return }
                try? model.mutateMeeting(id) { $0.brief = brief }
                model.notesChanged(id)
                if model.meetingSnapshot(id)?.retention == "finalized" { _ = VaultHookup.shared?.write(meetingID: id) }
            }
            synthesis[id] = (jobID, job)
        }
        return success
    }
    @discardableResult private func run(_ id: String, model: AppModel, final: Bool) async -> Bool {
        guard (final || !model.liveAIPaused), !running.contains(id), var snapshot = model.meetingSnapshot(id),
              snapshot.retention != "purged", snapshot.retention != "purging" else { return false }
        if CurrentNoteEngine.revalidate(&snapshot) {
            try? model.mutateMeeting(id) { $0.notes = snapshot.notes }
            model.notesChanged(id)
        }
        let generation = model.recordingGeneration
        let previousRun = lastRun[id]
        running.insert(id); dirty.remove(id); lastRun[id] = Date()
        defer {
            running.remove(id)
            if dirty.contains(id) { inputs[id] = nil; schedule(id, model: model) }
        }
        do {
            let prepared: Enrichment?
            // After Stop no more speech will come: answer every waiting jot in one pass and settle the rest.
            let stopped = snapshot.status != "recording"
            prepared = try await enhancer.enhance(snapshot, incremental: !final && !stopped) { patch in
                await MainActor.run {
                    guard model.recordingGeneration == generation,
                          model.meetingSnapshot(id)?.recordingSessions?.last?.id == snapshot.recordingSessions?.last?.id else { return }
                    try? model.mutateMeeting(id) { meeting in
                        for target in patch.plan.targets where patch.outcomes[target.note.id] == nil {
                            if let i = meeting.notes?.firstIndex(where: { $0.id == target.note.id && $0.queryRevision == target.note.queryRevision && $0.line.state == .listening }) {
                                meeting.notes![i].line.state = .found
                            }
                        }
                        if CurrentNoteEngine.apply(patch, to: &meeting, final: false) { self.dirty.insert(id) }
                    }
                    model.notesChanged(id)
                }
            }
            if let prepared, prepared.plan.targets.contains(where: { prepared.outcomes[$0.note.id] == nil }) { dirty.insert(id) }
            guard prepared != nil else {
                // After Stop, finding nothing settles a jot only if the search could see the transcript; an index
                // still loading after launch is asked again shortly.
                let searched = await enhancer.searched(id)
                if final || stopped && searched { try model.mutateMeeting(id) { meeting in
                    for i in (meeting.notes ?? []).indices { meeting.notes![i].line.settle() }
                } }
                if stopped, !final, !searched, (waits[id] ?? 0) < 20 {
                    waits[id, default: 0] += 1
                    Task { [weak self, weak model] in
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        guard let self, let model else { return }
                        inputs[id] = nil; schedule(id, model: model)
                    }
                }
                // Searching without a model call must not delay the first answer to later speech.
                lastRun[id] = previousRun
                return true
            }
            guard model.recordingGeneration == generation,
                  model.meetingSnapshot(id)?.recordingSessions?.last?.id == snapshot.recordingSessions?.last?.id,
                  model.meetingSnapshot(id)?.endedAt == snapshot.endedAt else { return false }
            // A live pass cut short still applies the lines it finished; they passed every check.
            if final { try Task.checkCancellation() }
            if final || stopped {
                try model.mutateMeeting(id) { meeting in
                    for i in (meeting.notes ?? []).indices { meeting.notes![i].line.settle() }
                }
            }
            model.notesChanged(id)
            if snapshot.retention == "finalized" { _ = VaultHookup.shared?.write(meetingID: id) }
            return true
        } catch {
            guard model.recordingGeneration == generation else { return false }
            // Superseded by Stop's final pass: not a failure to show.
            if !final, error is CancellationError || Task.isCancelled { return false }
            model.message = "AI lines paused · your notes are saving"
            return false
        }
    }
}
