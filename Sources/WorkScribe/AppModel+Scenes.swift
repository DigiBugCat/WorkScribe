import Foundation
import WorkScribeCore

extension IndexService {
    /// The meeting's screen moments that bear on `question`: by its words, and by meaning when an embedding is allowed.
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
        return selected.map { Self.sceneMoment($0, meeting: meeting, folder: try? model.store.directory(meeting.id)) }
    }
    static func sceneMoment(_ scene: ScreenMoment, meeting: Meeting, folder: URL?) -> AskMoment {
        var result = AskMoment(id: "screen:\(scene.id)", sourceKind: "meeting", ref: meeting.id, title: meeting.title,
                               kind: "screen", start: scene.start, end: scene.end,
                               text: scene.text.isEmpty ? "On screen: \(scene.context ?? "a window with no readable text")" : scene.searchText,
                               snippet: scene.text.isEmpty ? scene.context ?? "On screen" : String(scene.text.prefix(300)), attached: true)
        result.window = scene.context
        result.thumbnail = scene.thumbnail.map { folder?.appendingPathComponent($0).path ?? $0 }
        return result
    }
}
