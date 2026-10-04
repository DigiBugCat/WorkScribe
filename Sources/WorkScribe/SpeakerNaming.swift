import Foundation
import WorkScribeCore

struct SpeakerUndo {
    var speakers: [String: SpeakerAssignment]?
    var segments: [String: SpeakerAssignment]?
}

@MainActor extension AppModel {
    func latestMeeting(_ id: String) -> Meeting? { meeting?.id == id ? meeting : try? store.load(id) }
    func persistIdentity(_ entry: Meeting) throws {
        try store.save(entry)
        if meeting?.id == entry.id { meeting = entry }
        library = store.list()
    }
    /// Invalidate inference before a human edit. Rebuild examples from the latest labels.
    func invalidateVoices(id: String) throws {
        voiceTasks[id]?.cancel(); voiceTasks.removeValue(forKey: id)
        voiceTaskTokens.removeValue(forKey: id); voiceJobs.remove(id)
        var updated = voices
        for index in updated.indices { updated[index].samples.removeAll { $0.meetingID == id } }
        try voiceStore.save(updated); voices = updated
    }
    @discardableResult func nameSpeaker(meetingID: String, segmentID: String, name: String,
                                       profileID: String?, wholeSpeaker: Bool, remember: Bool) -> Bool {
        guard var entry = latestMeeting(meetingID), let segment = entry.segments.first(where: { $0.id == segmentID }) else { return false }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !trimmed.isEmpty else { return false }
        do {
            try invalidateVoices(id: entry.id)
            var selected = profileID.flatMap { id in voices.first { $0.id == id } }
            if remember && selected == nil {
                selected = voices.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
                if selected == nil {
                    let new = VoiceProfile(name: trimmed)
                    try voiceStore.save(voices + [new]); voices.append(new); selected = new
                }
            }
            speakerUndo[entry.id] = SpeakerUndo(speakers: entry.speakerAssignments, segments: entry.segmentAssignments)
            let assignment = SpeakerAssignment(name: selected?.name ?? trimmed, profileID: selected?.id, remember: remember)
            if wholeSpeaker && segment.speaker != "\(segment.source):unknown" && !segment.speaker.hasSuffix("-0") {
                if entry.speakerAssignments == nil { entry.speakerAssignments = [:] }
                entry.speakerAssignments?[segment.speaker] = assignment
                // Explicitly choosing all replaces exceptions for this speaker.
                for other in entry.segments where other.speaker == segment.speaker { entry.segmentAssignments?.removeValue(forKey: other.id) }
            } else {
                if entry.segmentAssignments == nil { entry.segmentAssignments = [:] }
                entry.segmentAssignments?[segment.id] = assignment
            }
            entry.voiceRevision = (entry.voiceRevision ?? 0) + 1
            entry.speakerSuggestions = nil
            try persistIdentity(entry)
            voiceStatus = entry.status == "recording" ? "Voice samples will be learned when recording ends" : "Speaker name saved"
            analyzeVoices(id: entry.id)
            return true
        } catch { voiceStatus = "Couldn’t save speaker: \(error.localizedDescription)"; return false }
    }
    func clearSpeaker(meetingID: String, segmentID: String, wholeSpeaker: Bool) {
        guard var entry = latestMeeting(meetingID), let segment = entry.segments.first(where: { $0.id == segmentID }) else { return }
        do {
            try invalidateVoices(id: entry.id)
            speakerUndo[entry.id] = SpeakerUndo(speakers: entry.speakerAssignments, segments: entry.segmentAssignments)
            if wholeSpeaker {
                entry.speakerAssignments?.removeValue(forKey: segment.speaker)
                for other in entry.segments where other.speaker == segment.speaker { entry.segmentAssignments?.removeValue(forKey: other.id) }
            } else {
                if entry.segmentAssignments == nil { entry.segmentAssignments = [:] }
                entry.segmentAssignments?[segment.id] = .original
            }
            entry.voiceRevision = (entry.voiceRevision ?? 0) + 1
            entry.speakerSuggestions?.removeValue(forKey: segment.speaker)
            try persistIdentity(entry); voiceStatus = "Original speaker label restored"
            // Do not immediately suggest the just-rejected identity again.
        } catch { voiceStatus = "Couldn’t restore speaker: \(error.localizedDescription)" }
    }
    func undoSpeakerChange(id: String) {
        guard let undo = speakerUndo[id], var entry = latestMeeting(id) else { return }
        do {
            try invalidateVoices(id: id)
            entry.speakerAssignments = undo.speakers; entry.segmentAssignments = undo.segments
            entry.speakerSuggestions = [:]; entry.voiceRevision = (entry.voiceRevision ?? 0) + 1
            try persistIdentity(entry); speakerUndo.removeValue(forKey: id)
            analyzeVoices(id: id)
        } catch { voiceStatus = "Couldn’t undo speaker change: \(error.localizedDescription)" }
    }
    func renameVoice(id: String, name: String) {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !clean.isEmpty, let index = voices.firstIndex(where: { $0.id == id }) else { return }
        var updated = voices; updated[index].name = clean
        do { try voiceStore.save(updated); voices = updated; voiceGeneration += 1; for task in voiceTasks.values { task.cancel() }; voiceTasks = [:]; voiceTaskTokens = [:]; voiceJobs = []; voiceStatus = "Name updated for future labels" }
        catch { voiceStatus = "Couldn’t rename voice: \(error.localizedDescription)" }
    }
    func forgetVoice(id: String) {
        do {
            let updated = voices.filter { $0.id != id }
            try voiceStore.save(updated); voices = updated; voiceGeneration += 1
            for task in voiceTasks.values { task.cancel() }; voiceTasks = [:]; voiceTaskTokens = [:]; voiceJobs = []
            // Historical confirmed names remain readable; forgetting removes reuse and samples.
            for var entry in store.list() {
                if meeting?.id == entry.id, let current = meeting { entry = current }
                for key in Array(entry.speakerAssignments?.keys ?? Dictionary<String, SpeakerAssignment>().keys) where entry.speakerAssignments?[key]?.profileID == id {
                    entry.speakerAssignments?[key]?.profileID = nil; entry.speakerAssignments?[key]?.remember = false
                }
                for key in Array(entry.segmentAssignments?.keys ?? Dictionary<String, SpeakerAssignment>().keys) where entry.segmentAssignments?[key]?.profileID == id {
                    entry.segmentAssignments?[key]?.profileID = nil; entry.segmentAssignments?[key]?.remember = false
                }
                entry.speakerSuggestions = entry.speakerSuggestions?.filter { $0.value.profileID != id }
                try persistIdentity(entry)
            }
            speakerUndo = [:]; voiceStatus = "Voice forgotten. Existing transcript names are preserved."
        } catch { voiceStatus = "Couldn’t finish forgetting voice: \(error.localizedDescription)" }
    }
    func analyzeVoices(id: String) {
        guard voiceTasks[id] == nil, let snapshot = latestMeeting(id), snapshot.status == "complete",
              !voices.isEmpty, let folder = try? store.directory(id) else { return }
        guard snapshot.sourceOffsets != nil else { voiceStatus = "Name saved. Older recordings lack audio alignment for voice learning."; return }
        let generation = voiceGeneration, revision = snapshot.voiceRevision ?? 0
        voiceJobs.insert(id)
        let token = UUID(); voiceTaskTokens[id] = token
        voiceTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { if voiceTaskTokens[id] == token { voiceJobs.remove(id); voiceTasks.removeValue(forKey: id); voiceTaskTokens.removeValue(forKey: id) } }
            do {
                let extracted = try await voiceEngine.extract(meeting: snapshot, folder: folder)
                guard !Task.isCancelled, generation == voiceGeneration, voiceTaskTokens[id] == token,
                      var latest = latestMeeting(id), (latest.voiceRevision ?? 0) == revision else { return }
                var updated = voices
                for index in updated.indices { updated[index].samples.removeAll { $0.meetingID == id } }
                for sample in extracted {
                    guard let segment = latest.segments.first(where: { $0.id == sample.segmentID }),
                          let assignment = latest.assignment(for: segment), assignment.remember,
                          let index = updated.firstIndex(where: { $0.id == assignment.profileID }) else { continue }
                    updated[index].samples.append(VoiceSample(meetingID: id, segmentID: segment.id, vector: sample.vector))
                    updated[index].samples = Array(updated[index].samples.suffix(12))
                }
                latest.speakerSuggestions = [:]
                for speaker in Set(latest.segments.map(\.speaker)) {
                    let segments = latest.segments.filter { $0.speaker == speaker && latest.assignment(for: $0) == nil && latest.segmentAssignments?[$0.id] == nil }
                    let ids = Set(segments.map(\.id))
                    let vectors = extracted.filter { ids.contains($0.segmentID) }.map(\.vector)
                    if let suggestion = VoiceMatching.suggest(vectors: vectors, profiles: updated, excluding: id) { latest.speakerSuggestions?[speaker] = suggestion }
                }
                try voiceStore.save(updated); voices = updated
                try persistIdentity(latest)
                voiceStatus = extracted.isEmpty ? "Name saved. Need three seconds of clear speech to learn this voice." : "Local voice profiles updated"
            } catch {
                if !Task.isCancelled { voiceStatus = "Voice matching unavailable: \(error.localizedDescription). Speaker names are saved." }
            }
        }
    }
}
