import AppKit
import Foundation
import WorkScribeCore

/// When the screen is read.
enum ScreenReadingMode: String, CaseIterable, Identifiable {
    case off
    /// Only while a meeting is being recorded.
    case meetings
    /// All day; a meeting being recorded keeps what is read during it.
    case allDay
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Off"
        case .meetings: "During meetings"
        case .allDay: "All day"
        }
    }
}

/// The app whose window is being read.
struct ScreenAppRef: Equatable {
    var name: String
    var bundleID: String?
}

/// A day's stretches of each app in front, and the local midnight their times count from.
struct DayUsage: Equatable {
    var start = ScreenDayStore.day(Date()).start
    var spans: [AppSpan] = []
}

/// Screen reading. Hooks for the UI:
///
/// - Settings: `screenMode`, `screenHistoryDays`, `screenDenyList` (`setScreenReading(_:for:)`).
/// - Now: `screenState` (+ `.label`), `screenCapturePaused`, `pauseScreen(minutes:)`.
/// - The day: `screenToday` (by app), `screenDays` (the journals), `deleteScreenDay(_:)`.
/// - A recording: `screenMoments`, `deleteScreenRecording(id:)`, `screenMoments(for:)`, `liveContext()`.
extension AppModel {
    /// Bundle IDs whose windows are never read (`ScreenPrivacy.defaultDeniedBundleIDs` until edited).
    var screenDenyList: [String] {
        get { UserDefaults.standard.stringArray(forKey: "screenDenyList") ?? ScreenPrivacy.defaultDeniedBundleIDs }
        set {
            UserDefaults.standard.set(newValue, forKey: "screenDenyList"); objectWillChange.send()
            screenWatcher?.setDenied(newValue)
        }
    }

    /// Whether `bundleID`'s windows may be read.
    func screenReads(_ bundleID: String) -> Bool { !ScreenPrivacy.isDenied(bundleID, list: screenDenyList) }

    /// Never read this app's windows, or read them again. Takes effect at once.
    func setScreenReading(_ allowed: Bool, for bundleID: String) {
        var list = screenDenyList.filter { $0.caseInsensitiveCompare(bundleID) != .orderedSame }
        if !allowed { list.append(bundleID) }
        screenDenyList = list
    }

    /// How many days of screen history are kept (today counts as one); zero keeps everything.
    var screenHistoryDays: Int {
        get { UserDefaults.standard.object(forKey: "screenHistoryDays") as? Int ?? 7 }
        set { UserDefaults.standard.set(newValue, forKey: "screenHistoryDays"); objectWillChange.send(); pruneScreenHistory() }
    }

    private func makeWatcher(keepingDay: Bool) -> ScreenWatcher {
        let watcher = ScreenWatcher(dayStore: keepingDay ? screenDays : nil, deniedBundleIDs: screenDenyList)
        watcher.onState = { [weak self] state in self?.screenState = state }
        watcher.onMeetingMoments = { [weak self] id, moments in
            guard let self, meeting?.id == id else { return }
            screenMoments = moments
            meeting?.screen?.momentCount = moments.count
        }
        watcher.onDay = { [weak self] totals, count, start, spans in
            self?.screenToday = totals; self?.screenTodayMoments = count
            self?.screenUsage = DayUsage(start: start, spans: spans)
        }
        watcher.onApp = { [weak self] app in self?.screenApp = ScreenAppRef(name: app.name ?? app.bundleID ?? "this app", bundleID: app.bundleID) }
        watcher.onHiddenApp = { [weak self] bundleID in self?.screenHiddenBundleID = bundleID }
        watcher.onDayMomentEnded = { [weak self] in self?.onScreenDayChanged?(false) }
        return watcher
    }

    /// Asks macOS, once, for what reading the screen needs: Accessibility for a window's text, Screen Recording
    /// for a picture of the window when it has none. After that, asking is left to the setting itself.
    private func askForScreenPermissionsOnce() {
        guard !ScreenReader.accessibilityAllowed || !ScreenReader.picturesAllowed else { return }
        guard !UserDefaults.standard.bool(forKey: "screenPermissionsAsked") else { return }
        UserDefaults.standard.set(true, forKey: "screenPermissionsAsked")
        if !ScreenReader.accessibilityAllowed { ScreenReader.askForAccessibility() }
        if !ScreenReader.picturesAllowed { screenAccess = CGRequestScreenCaptureAccess() }
    }

    /// Brings the watcher in line with the setting: reading all day, or only while a meeting is recorded.
    /// Safe to call again and again (it is, every few seconds, until the Mac allows reading windows).
    func applyScreenMode() async {
        guard screenReadingArmed, !busy, !quitting else { return }
        if screenMode != .off { askForScreenPermissionsOnce() }
        if screenMode == .allDay {
            guard screenWatcher == nil else { return }
            guard ScreenReader.accessibilityAllowed || ScreenReader.picturesAllowed else {
                // Asked again every few seconds until allowed: say so once, not each time.
                let waiting = ScreenCaptureState.unavailable("Allow Accessibility (to read window text) or Screen Recording in System Settings › Privacy & Security")
                if screenState != waiting { screenState = waiting }
                return
            }
            let watcher = makeWatcher(keepingDay: true)
            do {
                try watcher.start(); screenWatcher = watcher
                if screenCapturePaused { watcher.setPaused(true) }
                if let today = screenDays.load(ScreenDayStore.day(Date()).id) {
                    screenToday = today.byApp(); screenTodayMoments = today.moments.count
                    screenUsage = DayUsage(start: today.start, spans: today.usage)
                }
                pruneScreenHistory()
            } catch { screenState = .unavailable(error.localizedDescription) }
        } else if let watcher = screenWatcher {
            // Reading outside meetings was turned off.
            screenWatcher = nil
            await watcher.stop()
            screenState = .off; screenCapturePaused = false
        } else if screenMode == .off {
            screenState = .off
        }
    }

    /// The meeting being recorded starts keeping what is read. Never throws: a failure leaves audio recording and
    /// is shown through `screenState` and the meeting's `screen.failure`.
    func startScreen() async {
        screenMoments = meeting.map { store.loadScreenMoments($0.id) } ?? []
        guard let current = meeting else { return }
        guard screenMode != .off, screenReadingArmed else { screenState = .off; return }
        if screenWatcher == nil {
            // Only for this recording, unless the day is being read too and its watcher could not start earlier.
            let watcher = makeWatcher(keepingDay: screenMode == .allDay)
            do { try watcher.start(); screenWatcher = watcher }
            catch {
                screenState = .unavailable(error.localizedDescription)
                meeting?.screen = ScreenCaptureInfo(target: "window", state: "failed", failure: error.localizedDescription)
                try? save()
                return
            }
            screenCapturePaused = false
        }
        guard let watcher = screenWatcher else { return }
        let begun = await watcher.beginMeeting(id: current.id, timeline: MeetingScreenTimeline(store: store, meetingID: current.id, start: current.startedAt))
        screenMeetingToken = begun.token
        guard meeting?.id == current.id else { return }
        meeting?.screen = begun.info
        try? save()
    }

    /// The meeting stops keeping what is read. An all-day watcher carries on into the day's journal.
    func stopScreen() async {
        callBundleID = nil
        guard let watcher = screenWatcher else { return }
        let result: (id: String, info: ScreenCaptureInfo, moments: [ScreenMoment])?
        if watcher.keepsDay {
            // Ends the stretch this stop belongs to, and only that one (the meeting may be resumed before this returns).
            guard let token = screenMeetingToken else { return }
            screenMeetingToken = nil
            result = await watcher.endMeeting(token)
        } else {
            screenWatcher = nil
            result = await watcher.stop()
            screenCapturePaused = false
        }
        guard let result, meeting?.id == result.id else { return }
        meeting?.screen = result.info
        if let index = meeting?.recordingSessions?.indices.last { meeting?.recordingSessions?[index].screen = result.info }
        screenMoments = result.moments
        try? save()
        if !watcher.keepsDay, result.info.failure == nil { screenState = .off }
    }

    /// Quitting: what is open in the day's journal is written, and reading stops.
    func shutdownScreen() async {
        screenPauseTask?.cancel(); screenPauseTask = nil
        guard let watcher = screenWatcher else { return }
        screenWatcher = nil
        await watcher.stop()
    }

    /// Pauses screen reading: nothing is read or kept until it resumes. With `minutes`, it resumes by itself.
    func pauseScreen(minutes: Double? = nil) {
        screenPauseTask?.cancel(); screenPauseTask = nil
        screenCapturePaused = true
        guard let minutes else { return }
        screenPauseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes * 60 * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            screenPauseTask = nil; screenCapturePaused = false
        }
    }
    func resumeScreen() {
        screenPauseTask?.cancel(); screenPauseTask = nil
        screenCapturePaused = false
    }

    // MARK: The day's history

    /// Removes journals older than `screenHistoryDays`, and their rows in the search index.
    func pruneScreenHistory() {
        nextScreenPrune = Date().addingTimeInterval(3_600)
        guard screenReadingArmed else { return }
        if let gone = try? screenDays.prune(keeping: screenHistoryDays), !gone.isEmpty { onScreenDayChanged?(true) }
    }

    /// Deletes one day of screen history, today's included (it is also forgotten in memory, so it cannot be written back).
    func deleteScreenDay(_ day: String) async {
        if day == ScreenDayStore.day(Date()).id, let watcher = screenWatcher, watcher.keepsDay {
            await watcher.clearToday()
        } else {
            try? screenDays.delete(day)
        }
        if day == ScreenDayStore.day(Date()).id { screenToday = []; screenTodayMoments = 0; screenUsage = DayUsage() }
        onScreenDayChanged?(true)
        objectWillChange.send()
    }

    /// Forgets what was read from one app on one day (its text, and that it was in front).
    func forgetScreenApp(_ bundleID: String, day: String) async {
        if day == ScreenDayStore.day(Date()).id, let watcher = screenWatcher, watcher.keepsDay {
            await watcher.forgetApp(bundleID)
        } else if var whole = screenDays.load(day) {
            whole.forget(bundleID: bundleID); try? screenDays.save(whole)
        }
        onScreenDayChanged?(true)
        objectWillChange.send()
    }

    func deleteAllScreenHistory() async {
        for day in screenDays.days() { await deleteScreenDay(day) }
        message = "Screen history deleted"
    }

    // MARK: A recording's screen text

    /// Moves a meeting's screen text to the Trash; audio and transcript stay.
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

    /// Context for a live answer during the current recording: recent transcript plus what's on screen now and was
    /// recently. Empty when nothing is recording.
    func liveContext(seconds: Double = 120) -> String {
        guard let meeting, phase == "recording" else { return "" }
        return LiveContext.compose(meeting: meeting, screen: screenMoments, now: Date().timeIntervalSince(meeting.startedAt),
                                   window: seconds, current: ScreenContext.current(maxAge: 30))
    }
}
