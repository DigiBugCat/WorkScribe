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

/// Connects the app's lifecycle to semantic indexing: admit work by ASR pressure, index live finalized turns.
/// The search UI itself is still being designed; `service.search` is what it will call.
@MainActor
final class SearchHookup {
    let service: IndexService
    private var observations = Set<AnyCancellable>()

    init(model: AppModel, service: IndexService) {
        self.service = service
        model.$recordingPressure.sink { pressure in
            Task { await service.setPressure(pressure) }
        }.store(in: &observations)
        // Stop leaves the phase at finalizing while it drains ASR. The complete/
        // interrupted meeting status is published after that drain, before final notes.
        model.$meeting.compactMap { $0 }.sink { meeting in
            if meeting.status == "complete" || meeting.status == "interrupted" {
                Task {
                    await service.liveChanged(meeting)
                    await service.setPressure(.normal)
                }
            }
        }.store(in: &observations)
        model.$meeting.compactMap { $0 }
            .sink { [weak model] meeting in
                guard model?.phase == "recording", model?.meeting?.id == meeting.id,
                      meeting.status == "recording" else { return }
                Task { await service.liveChanged(meeting) }
            }.store(in: &observations)
        model.$phase.removeDuplicates().sink { phase in
            if phase == "finalizing" { Task { await service.finishLive() } }
            if !["starting", "recording", "finalizing"].contains(phase) {
                Task { await service.finishLive(); await service.setPressure(.normal); await service.meetingsChanged() }
            }
        }.store(in: &observations)
        Task { await service.meetingsChanged(); await service.foldersChanged() }
        model.onLibraryChanged = { Task { await service.meetingsChanged() } }
    }
}
