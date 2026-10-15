import AppKit
import Combine
import Foundation
import WorkScribeCore

extension Notification.Name {
    /// Posted after a `workscribe://meeting/…` link selects a meeting. userInfo: "meeting_id", and when present
    /// "seconds" (Double) and "segment_id" (String). The same request is kept in `AppModel.focusRequest`, which
    /// TranscriptView scrolls to and highlights (a view that appears after the post still sees it).
    static let workScribeFocus = Notification.Name("WorkScribeFocus")
}

extension AppModel {
    /// Routes a deep link. Meetings open in the transcript view; files open at their page or time in a viewer
    /// window (PDFs, audio, video), anything else in its default app.
    func open(_ link: WorkScribeLink) {
        switch link {
        case .meeting(let id, let seconds, let segment):
            guard library.contains(where: { $0.id == id }) || meeting?.id == id else { return }
            selectedID = id
            focusRequest = TranscriptFocus(meetingID: id, seconds: seconds, segmentID: segment)
            var info: [String: Any] = ["meeting_id": id]
            if let seconds { info["seconds"] = seconds }
            if let segment { info["segment_id"] = segment }
            NotificationCenter.default.post(name: .workScribeFocus, object: self, userInfo: info)
        case .file(let path, let page, let seconds):
            guard FileManager.default.fileExists(atPath: path) else { return }
            FileMomentViewer.open(URL(fileURLWithPath: path), page: page, seconds: seconds)
        }
    }
}

/// Connects the app's lifecycle to semantic indexing: pause while recording, index meetings once they're saved.
/// The search UI itself is still being designed; `service.search` is what it will call.
@MainActor
final class SearchHookup {
    let service: IndexService
    private var observation: AnyCancellable?
    private var wasBusy = false

    init(model: AppModel, service: IndexService) {
        self.service = service
        observation = model.$phase.receive(on: RunLoop.main).sink { [weak self] phase in
            guard let self else { return }
            let busy = phase == "starting" || phase == "recording" || phase == "finalizing"
            guard busy != wasBusy else { return }
            wasBusy = busy
            Task {
                await service.setPaused(busy)
                if !busy { await service.meetingsChanged() }
            }
        }
        let busy = model.phase == "starting" || model.phase == "recording" || model.phase == "finalizing"
        wasBusy = busy
        Task { await service.setPaused(busy); await service.meetingsChanged(); await service.foldersChanged() }
        model.onLibraryChanged = { Task { await service.meetingsChanged() } }
    }
}
