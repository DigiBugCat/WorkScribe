import AppKit
import Foundation
import WorkScribeCore

/// Screen awareness for the recording lifecycle. Hooks for the UI:
///
/// - Settings: `screenCaptureEnabled`, `screenCaptureTarget` (.display / .window), `screenDenyList`.
/// - During a recording: `screenCapturePaused` (toggle), `screenState` (+ `.label`), `screenMoments`.
/// - Live answers: `liveContext()` (transcript + screen text) or `ScreenContext.current(maxAge:)` for just the screen.
/// - Per meeting: `deleteScreenRecording(id:)`; `screenMoments(for:)`, `screenThumbnailURL(_:meetingID:)`,
///   `screenVideoURL(for:)` to show a moment's picture or seek the video (video time = meeting time − `screen.offset`).
extension AppModel {
    /// Bundle IDs whose windows are never recorded or read (`ScreenPrivacy.defaultDeniedBundleIDs` until edited).
    var screenDenyList: [String] {
        get { UserDefaults.standard.stringArray(forKey: "screenDenyList") ?? ScreenPrivacy.defaultDeniedBundleIDs }
        set { UserDefaults.standard.set(newValue, forKey: "screenDenyList"); objectWillChange.send() }
    }

    /// Starts screen capture for the meeting being recorded. Never throws: a failure leaves audio recording and is
    /// shown through `screenState` and the meeting's `screen.failure`.
    func startScreen() async {
        screenCapturePaused = false; screenMoments = meeting.map { store.loadScreenMoments($0.id) } ?? []
        guard let current = meeting, let folder = try? store.directory(current.id) else { return }
        guard screenCaptureEnabled else { screenState = .off; return }
        guard CGPreflightScreenCaptureAccess() else {
            screenState = .unavailable("Allow Screen Recording to capture the screen with meetings")
            return
        }
        var settings = ScreenCaptureSettings()
        settings.target = screenCaptureTarget
        settings.deniedBundleIDs = screenDenyList
        let recorder = ScreenRecorder(folder: folder, meetingID: current.id, meetingStart: current.startedAt, store: store, settings: settings, videoFile: current.recordingSessions?.last?.videoFile ?? ScreenFiles.video)
        recorder.onState = { [weak self] state in
            guard let self, self.meeting?.id == current.id else { return }
            self.screenState = state
        }
        recorder.onMoments = { [weak self] moments in
            guard let self, meeting?.id == current.id else { return }
            screenMoments = moments
            meeting?.screen?.momentCount = moments.count
        }
        screenRecorder = recorder
        do {
            // Await first, then write: `meeting?.screen = try await …` reads the whole meeting
            // before the await and writes that stale copy back after it, erasing whatever the
            // audio pumps recorded meanwhile (the microphone's clock offset, first segments).
            let info = try await recorder.start(callBundleID: callBundleID)
            meeting?.screen = info
            try? save()
        } catch {
            screenRecorder = nil
            screenState = .failed(error.localizedDescription)
            meeting?.screen = ScreenCaptureInfo(target: screenCaptureTarget.rawValue, state: "failed", failure: error.localizedDescription)
            try? save()
        }
    }

    func stopScreen() async {
        callBundleID = nil
        guard let recorder = screenRecorder else { return }
        screenRecorder = nil
        let result = await recorder.stop()
        guard meeting?.id == recorder.meetingID else { return }
        if meeting?.id == recorder.meetingID {
            meeting?.screen = result.info
            if let index = meeting?.recordingSessions?.indices.last { meeting?.recordingSessions?[index].screen = result.info }
            screenMoments = result.moments
            try? save()
        }
        if !(screenState == .off) && result.info.failure == nil { screenState = .off }
        screenCapturePaused = false
    }

    /// Moves a meeting's screen video, thumbnails and screen text to the Trash; audio and transcript stay.
    func deleteScreenRecording(id: String) {
        guard !(busy && meeting?.id == id) else { message = "Stop recording before deleting its screen recording"; return }
        do {
            let updated = try store.deleteScreenCapture(id)
            if meeting?.id == id { meeting = updated; screenMoments = [] }
            library = store.list(); message = "Screen recording moved to the Trash"
            onLibraryChanged?()
        } catch { message = "Couldn’t delete the screen recording: \(error.localizedDescription)" }
    }

    func screenMoments(for id: String) -> [ScreenMoment] {
        meeting?.id == id && busy ? screenMoments : store.loadScreenMoments(id)
    }

    func screenThumbnailURL(_ moment: ScreenMoment, meetingID: String) -> URL? {
        guard let path = moment.thumbnail, let folder = try? store.directory(meetingID) else { return nil }
        return folder.appendingPathComponent(path)
    }

    func screenVideoURL(for meeting: Meeting, at time: Double? = nil) -> URL? {
        let info = time.flatMap { t in meeting.recordingSessions?.last(where: { $0.start <= t && ($0.end == nil || t <= $0.end!) })?.screen } ?? meeting.screen
        guard let file = info?.file, let folder = try? store.directory(meeting.id) else { return nil }
        return folder.appendingPathComponent(file)
    }

    /// Context for a live answer during the current recording: recent transcript plus what's on screen now and was
    /// recently. Empty when nothing is recording.
    func liveContext(seconds: Double = 120) -> String {
        guard let meeting, phase == "recording" else { return "" }
        return LiveContext.compose(meeting: meeting, screen: screenMoments, now: Date().timeIntervalSince(meeting.startedAt),
                                   window: seconds, current: ScreenContext.current(maxAge: 30))
    }
}
