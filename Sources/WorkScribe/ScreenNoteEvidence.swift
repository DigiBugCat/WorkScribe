import Foundation
import WorkScribeCore

/// Adds scene evidence to the prompt copy only. User words and transcript/excerpt identity stay intact.
enum ScreenNoteEvidence {
    @MainActor static var store: MeetingStore?
    @MainActor static weak var model: AppModel?

    static func add(to plan: inout NotePlan, meeting: Meeting) async -> [String: [TraceSource]] {
        let context = await MainActor.run { (store, model?.recordingPressure ?? .normal, model?.screenRecorder) }
        guard let store = context.0, context.1 == .normal, ProcessInfo.processInfo.thermalState == .nominal else { return [:] }
        let scenes = store.loadScreenMoments(meeting.id)
        var result: [String: [TraceSource]] = [:]
        var budget = 3
        for index in plan.targets.indices where budget > 0 {
            let note = plan.targets[index].note
            let selected = ScreenSceneRetrieval.ranked(scenes, question: note.text, at: note.createdAt, limit: 1)
            for scene in selected {
                context.2?.freezeRepresentative(scene.id)
                let read = await ScreenSceneText.shared.read(scene.id, meetingID: meeting.id, store: store) ?? scene
                guard !read.text.isEmpty else { continue }
                budget -= 1
                var evidence = NoteImage(target: "scene:\(scene.id)")
                evidence.text = "Screen at \(AskMoment.clock(read.start)) (OCR): " + String(read.text.prefix(1800))
                plan.targets[index].note.images = (plan.targets[index].note.images ?? []) + [evidence]
                let folder = try? store.directory(meeting.id)
                result[note.id] = [TraceSource(kind: "screen", title: read.context ?? "Screen scene", text: String(read.text.prefix(300)),
                    link: WorkScribeLink.meeting(id: meeting.id, seconds: read.start, segment: nil).url.absoluteString,
                    thumbnail: read.thumbnail.map { folder?.appendingPathComponent($0).path ?? $0 }, start: read.start, end: read.end)]
            }
        }
        return result
    }
}
