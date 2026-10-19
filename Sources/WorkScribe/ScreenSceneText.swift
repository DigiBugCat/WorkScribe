import Foundation
import ImageIO
import CoreGraphics
import WorkScribeCore

/// No image/OCR cache survives a request. One low-priority read globally; additional requests can retry later.
/// Disk state deduplicates completed (including empty/failed) reads across capture, Ask and relaunch.
actor ScreenSceneText {
    static let shared = ScreenSceneText()
    typealias Reader = @Sendable (CGImage) async -> (text: String, lines: [ScreenTextLine])
    private let reader: Reader
    private var busy = false
    init(reader: @escaping Reader = { await ScreenOCR.read($0) }) { self.reader = reader }

    func read(_ id: String, meetingID: String, store: MeetingStore, image: CGImage? = nil,
              allowed: @escaping @Sendable () -> Bool = { true }) async -> ScreenMoment? {
        guard !busy, ScreenInferenceAdmission.shared.allowsOCR, allowed(), !Task.isCancelled else { return nil }
        let input: (ScreenMoment, CGImage)? = ScreenFiles.mutationLock.withLock {
            guard let meeting = try? store.load(meetingID), meeting.retention != "purged", meeting.retention != "purging",
                  meeting.screen?.state != "deleted",
                  let scene = store.loadScreenMoments(meetingID).first(where: { $0.id == id }), scene.ocrState == nil else { return nil }
            // New sessions supply only transient frames. Disk fallback is read-only legacy support.
            if let image { return (scene, image) }
            guard let keyframe = scene.keyframe, keyframe == ScreenFiles.keyframe(id),
                  let folder = try? store.directory(meetingID),
                  let source = CGImageSourceCreateWithURL(folder.appendingPathComponent(keyframe) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return (scene, image)
        }
        guard let (scene, image) = input else { return nil }
        busy = true; defer { busy = false }
        guard ScreenInferenceAdmission.shared.allowsOCR, allowed(), !Task.isCancelled else { return nil }
        let reader = self.reader
        let result = await Task.detached(priority: .background) { await reader(image) }.value
        guard ScreenInferenceAdmission.shared.allowsOCR, allowed(), !Task.isCancelled else { return nil }
        return ScreenFiles.mutationLock.withLock {
            var scenes = store.loadScreenMoments(meetingID)
            guard let index = scenes.firstIndex(where: { $0.id == id && $0.representativeTime == scene.representativeTime }),
                  scenes[index].ocrState == nil,
                  let meeting = try? store.load(meetingID), meeting.retention != "purged", meeting.retention != "purging",
                  meeting.screen?.state != "deleted" else { return nil }
            scenes[index].text = result.text; scenes[index].lines = result.lines
            scenes[index].ocrState = result.text.isEmpty ? "empty" : "complete"
            do { try store.saveScreenMoments(scenes, id: meetingID); return scenes[index] } catch { return nil }
        }
    }
}

/// Thread-safe admission for OCR callers outside the recorder (Ask and note enhancement).
final class ScreenInferenceAdmission: @unchecked Sendable {
    static let shared = ScreenInferenceAdmission()
    private let lock = NSLock()
    private var pressure: RecordingPressure = .normal
    func set(_ value: RecordingPressure) { lock.withLock { pressure = value } }
    var allowsOCR: Bool { lock.withLock { pressure == .normal && ProcessInfo.processInfo.thermalState == .nominal } }
}
