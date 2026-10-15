import Foundation
import WorkScribeCore

extension AppModel {
    /// Bounded and on demand. Pressure wins even over an explicit Ask/note request.
    func readScene(_ scene: ScreenMoment, meetingID: String) async -> ScreenMoment {
        guard scene.ocrState == nil, recordingPressure == .normal,
              ProcessInfo.processInfo.thermalState == .nominal else { return scene }
        if self.meeting?.id == meetingID { screenRecorder?.freezeRepresentative(scene.id) }
        let read = await ScreenSceneText.shared.read(scene.id, meetingID: meetingID, store: store, allowed: { [weak self] in
            // The recorder's background work also checks its own pressure. MainActor reads cannot be
            // performed here; cancellation and the durable retention guard remain authoritative.
            self != nil && !Task.isCancelled
        })
        if read != nil {
            if self.meeting?.id == meetingID { screenMoments = store.loadScreenMoments(meetingID) }
            onLibraryChanged?() // A finalized scene's new OCR joins keyword search on the next index pass.
        }
        return read ?? scene
    }
}

extension IndexService {
    func scenes(_ scenes: [ScreenMoment], question: String, allowEmbedding: Bool, limit: Int = 3) async -> [ScreenMoment] {
        var vector: [Float]?
        if allowEmbedding, let embedder { vector = try? await embedder.text(question, role: .query) }
        return ScreenSceneRetrieval.ranked(scenes, question: question, vector: vector, modelID: embedder?.modelID, limit: limit)
    }
}

extension AskService {
    func sceneMoments(_ question: String, meeting: Meeting, scenes: [ScreenMoment], limit: Int) async -> [AskMoment] {
        let allowed = model.recordingPressure == .normal && ProcessInfo.processInfo.thermalState == .nominal
        let selected = await index?.scenes(scenes, question: question, allowEmbedding: allowed, limit: limit)
            ?? ScreenSceneRetrieval.ranked(scenes, question: question, limit: limit)
        var result: [AskMoment] = []
        for scene in selected {
            let scene = await model.readScene(scene, meetingID: meeting.id)
            result.append(Self.sceneMoment(scene, meeting: meeting, folder: try? model.store.directory(meeting.id)))
        }
        return result
    }
    static func sceneMoment(_ scene: ScreenMoment, meeting: Meeting, folder: URL?) -> AskMoment {
        var result = AskMoment(id: "screen:\(scene.id)", sourceKind: "meeting", ref: meeting.id, title: meeting.title,
                               kind: "screen", start: scene.start, end: scene.end,
                               text: scene.text.isEmpty ? "Visual scene; text has not been read. \(scene.context ?? "")" : scene.searchText,
                               snippet: scene.text.isEmpty ? scene.context ?? "Visual scene" : String(scene.text.prefix(300)), attached: true)
        result.window = scene.context
        result.thumbnail = scene.thumbnail.map { folder?.appendingPathComponent($0).path ?? $0 }
        return result
    }
}
