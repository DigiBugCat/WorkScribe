import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import WorkScribeCore

/// What screen capture is doing, for the UI.
enum ScreenCaptureState: Equatable {
    case off
    case starting
    case recording
    case paused
    /// A private app (deny list) or a private window is frontmost: nothing is read.
    case privateApp(String)
    /// Not attempted: disabled, or no permission to read windows.
    case unavailable(String)
    /// Capture stopped or never started; audio keeps recording.
    case failed(String)

    var label: String {
        switch self {
        case .off: "Screen reading off"
        case .starting: "Starting screen reading…"
        case .recording: "Reading screen text"
        case .paused: "Screen reading paused"
        case .privateApp(let name): "Screen text hidden while \(name) is in front"
        case .unavailable(let why): why
        case .failed(let why): "Screen reading stopped: \(why)"
        }
    }
    var isCapturing: Bool {
        switch self { case .recording, .paused, .privateApp: true; default: false }
    }
}

/// Where a meeting's readings are kept, and on which clock.
protocol ScreenTimeline: Sendable {
    /// Seconds on this timeline for a moment in time (meeting seconds).
    func seconds(_ date: Date) -> Double
    func load() -> [ScreenMoment]
    /// Saves the whole timeline. False when it may no longer be written (purged, deleted).
    func save(_ moments: [ScreenMoment]) -> Bool
}

struct MeetingScreenTimeline: ScreenTimeline {
    let store: MeetingStore
    let meetingID: String
    let start: Date
    func seconds(_ date: Date) -> Double { date.timeIntervalSince(start) }
    func load() -> [ScreenMoment] { store.loadScreenMoments(meetingID) }
    func save(_ moments: [ScreenMoment]) -> Bool { (try? store.saveScreenMoments(moments, id: meetingID)) != nil }
}

/// Watches the screen the way `ScreenWatch` decides: on events, one window at a time, text first.
///
/// Once a second it notes what changed (the window in front, whether the screen is locked, whether
/// the person just typed or clicked) and tells the reducer. When the reducer asks for a read,
/// `ScreenReader` reads that one app's focused window: its accessibility text, or, when there is too
/// little of that, a picture of the window read by Vision. No video, picture or frame is stored; a
/// picture lives only as long as its text is being read.
///
/// One watcher runs for as long as the screen is being read: all day, or for the length of a
/// recording. What the reducer lets through has exactly one home (`ScreenRoute`): the meeting being
/// recorded when the window was read, or else the day's journal. The journal also notes which app
/// was in front, and its window titles, for the whole day including meetings.
final class ScreenWatcher: @unchecked Sendable {
    /// Called on the main queue.
    var onState: ((ScreenCaptureState) -> Void)?
    /// Called on the main queue with the meeting being recorded and every moment of it so far.
    var onMeetingMoments: ((String, [ScreenMoment]) -> Void)?
    /// Called on the main queue after the day's journal was written: today by app, how many moments, and the
    /// day's app spans with the midnight their times count from.
    var onDay: (([AppTotal], Int, Date, [AppSpan]) -> Void)?
    /// Called on the main queue when the app whose window is being read changes.
    var onApp: ((ScreenWatch.App) -> Void)?
    /// Called on the main queue when an app on the never-read list comes to the front (its bundle identifier),
    /// and with nil when reading carries on.
    var onHiddenApp: ((String?) -> Void)?
    /// Called on the main queue when a stretch of the day ended and is on disk: worth indexing.
    var onDayMomentEnded: (() -> Void)?

    private struct MeetingSink {
        let id: String
        /// Which `beginMeeting` this is. A meeting that is resumed begins again under the same id.
        let token = UUID()
        let timeline: any ScreenTimeline
        let earlier: [ScreenMoment]
        var builder = ScreenMomentBuilder()
        var kept = 0
        var moments: [ScreenMoment] {
            earlier + builder.all.map { moment -> ScreenMoment in
                var moment = moment; moment.ocrState = "complete"; moment.thumbnail = nil; moment.keyframe = nil; return moment
            }
        }
    }

    private let queue = DispatchQueue(label: "WorkScribe.screen-watch", qos: .utility)
    private var watch: ScreenWatch
    private var route: ScreenRoute
    private var journal: ScreenDayJournal?
    private var meeting: MeetingSink?
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var front: ScreenWatch.App?
    private var title: String?
    private var announced: ScreenWatch.App?
    private var hidden: String?
    private var locked = false
    private var stopped = false
    private let limits = ScreenReader.Limits()
    private var denied: [String]
    private var failure: String?
    private let pictures = PictureMemory()
    /// What kind of app each bundle is, looked up once.
    private var categories: [String: String?] = [:]
    /// EmbeddingGemma's vision model, on this Mac: what a window looked like, as a vector to search by.
    private let embedder: CoreMLEmbedder?
    /// The time, in seconds. Tests move it by hand.
    var clock: @Sendable () -> Double = { Date().timeIntervalSinceReferenceDate }
    /// Reads one app's focused window. Tests, which have no screen to read, supply their own.
    var reader: (@Sendable (ScreenWatch.App, [String]) async -> ScreenWatch.Reading?)?

    /// `dayStore` is where readings outside meetings are kept; nil reads the screen only while a meeting is attached.
    init(dayStore: ScreenDayStore?, deniedBundleIDs: [String] = ScreenPrivacy.defaultDeniedBundleIDs,
         embedder: CoreMLEmbedder? = CoreMLEmbedder.bundled()) {
        denied = deniedBundleIDs
        self.embedder = embedder?.supportsImages == true ? embedder : nil
        var settings = ScreenWatch.Settings(); settings.deniedBundleIDs = deniedBundleIDs
        watch = ScreenWatch(settings: settings)
        route = ScreenRoute(keepsDay: dayStore != nil)
        journal = dayStore.map { ScreenDayJournal(store: $0) }
    }

    var keepsDay: Bool { route.keepsDay }

    // MARK: Lifecycle

    /// Starts watching. Throws when no window can be read at all: the caller carries on without the screen.
    @MainActor
    func start() throws {
        guard ScreenReader.accessibilityAllowed || ScreenReader.picturesAllowed else {
            throw CaptureError.message("Allow Accessibility (to read window text) or Screen Recording in System Settings › Privacy & Security")
        }
        publish(.starting)
        let own = ProcessInfo.processInfo.processIdentifier
        let note: (NSRunningApplication?) -> Void = { [weak self] app in
            guard let self else { return }
            // WorkScribe's own windows are not what the person is working on. Nor is one of the Mac's own
            // dialogs (a permission alert, a password prompt): it is neither read nor listed as an application.
            let value = app.flatMap { $0.processIdentifier == own || ScreenPrivacy.isSystemUI($0.bundleIdentifier) ? nil
                : ScreenWatch.App(name: $0.localizedName, bundleID: $0.bundleIdentifier, pid: $0.processIdentifier) }
            let declared = app?.bundleURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String }
            self.queue.async {
                if let id = value?.bundleID, self.categories[id] == nil {
                    self.categories[id] = .some(AppCategory.name(bundleID: id, declared: declared))
                }
                self.front = value; self.title = nil; self.pulse()
            }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) {
            note($0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        })
        note(NSWorkspace.shared.frontmostApplication)
        queue.async { [self] in
            apply(.start(now: now()))
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.pulse() }
            timer.resume(); self.timer = timer
        }
    }

    /// From now on, what is read belongs to this meeting. Returns what the meeting's `screen` should say, and
    /// the token that ends this stretch of it.
    func beginMeeting(id: String, timeline: any ScreenTimeline) async -> (info: ScreenCaptureInfo, token: UUID) {
        await withCheckedContinuation { done in
            queue.async { [self] in
                // A stretch that was never ended (its stop is still on its way) is closed first, so its last
                // moment is saved and the new stretch starts clean.
                _ = closeMeeting()
                let now = now()
                // The day's current stretch ends here; the meeting starts its own.
                journal?.endMoment(at: Date(timeIntervalSinceReferenceDate: now))
                route.begin(meeting: id, at: now)
                let sink = MeetingSink(id: id, timeline: timeline, earlier: timeline.load())
                meeting = sink
                flushDay(now, force: true)
                done.resume(returning: (info(state: "recording"), sink.token))
            }
        }
    }

    /// The meeting stopped: its timeline is closed, and reading goes back to the day (when there is one).
    /// Only the stretch that `token` began is ended: a stop that arrives late, after the meeting was resumed,
    /// must not end the resumed stretch and send the rest of the meeting's screen to the day.
    func endMeeting(_ token: UUID) async -> (id: String, info: ScreenCaptureInfo, moments: [ScreenMoment])? {
        await withCheckedContinuation { done in
            queue.async { [self] in done.resume(returning: meeting?.token == token ? closeMeeting() : nil) }
        }
    }

    private func closeMeeting() -> (id: String, info: ScreenCaptureInfo, moments: [ScreenMoment])? {
        guard var sink = meeting else { return nil }
        let now = now()
        sink.builder.close(at: sink.timeline.seconds(Date(timeIntervalSinceReferenceDate: now)))
        meeting = sink
        persistMeeting()
        let result = (sink.id, info(state: failure == nil ? "complete" : "failed"), sink.timeline.load())
        meeting = nil
        route.endMeeting(at: now)
        ScreenContext.shared.clear()
        return result
    }

    /// Pausing drops what was being read: nothing is read or kept until resumed.
    func setPaused(_ value: Bool) { queue.async { [self] in apply(.paused(value, now: now())) } }

    /// A busy Mac reads less: no pictures while recognition is behind (accessibility text costs nothing).
    func setPressure(_ value: RecordingPressure) { ScreenInferenceAdmission.shared.set(value) }

    /// The apps never to read changed. Takes effect at once: a read already asked of one of them is dropped.
    func setDenied(_ list: [String]) {
        queue.async { [self] in
            denied = list; watch.settings.deniedBundleIDs = list
            pulse()
        }
    }

    /// Forgets today's journal: the file, and what is held in memory, so it cannot be written back.
    func clearToday() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                try? journal?.clear()
                notifyDay()
                done.resume()
            }
        }
    }

    /// Forgets what was read from one app today, on disk and in memory.
    func forgetApp(_ bundleID: String) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                try? journal?.forget(bundleID: bundleID)
                notifyDay()
                done.resume()
            }
        }
    }

    /// Stops watching. Returns the meeting that was attached, if one was.
    @discardableResult
    func stop() async -> (id: String, info: ScreenCaptureInfo, moments: [ScreenMoment])? {
        await MainActor.run { observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers = [] }
        return await withCheckedContinuation { done in
            queue.async { [self] in
                timer?.cancel(); timer = nil
                apply(.stop(now: now()))
                stopped = true
                let result = closeMeeting()
                journal?.endUsage()
                flushDay(now(), force: true)
                pictures.clear(); ScreenContext.shared.clear()
                // Hand the vision model back, off the path that finishes the transcript.
                let model = embedder
                Task.detached(priority: .background) { await model?.release() }
                done.resume(returning: result)
            }
        }
    }

    /// A picture of the window in front, now, when that window may be read. For "grab this into my note".
    func grabMoment() async throws -> GrabMoment {
        let asked: (app: ScreenWatch.App, at: Double)? = await withCheckedContinuation { done in
            queue.async { [self] in
                guard watch.mode == .watching, let front, let sink = meeting else { done.resume(returning: nil); return }
                done.resume(returning: (front, sink.timeline.seconds(Date())))
            }
        }
        guard let asked, let image = await ScreenReader.picture(pid: asked.app.pid, title: nil) else {
            throw CaptureError.message("No current permitted window to grab. Screen reading must be on for this meeting, with Screen Recording allowed.")
        }
        // The person may have moved on, paused, or opened something private while the picture was taken.
        let still: Bool = await withCheckedContinuation { done in queue.async { done.resume(returning: self.watch.mode == .watching && self.front?.pid == asked.app.pid) } }
        guard still, !ScreenPrivacy.isPrivateWindow(ScreenReader.windowTitle(pid: asked.app.pid)) else {
            throw CaptureError.message("The window changed before it could be grabbed.")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError.message("Could not encode the screen image")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.message("Could not encode the screen image") }
        return GrabMoment(data: data as Data, at: asked.at)
    }

    // MARK: The pulse (on `queue`)

    private func now() -> Double { clock() }

    /// What changed since the last look: the window in front, the lock, input.
    private func pulse() {
        guard !stopped else { return }
        let isLocked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        if let front, !isLocked { title = ScreenReader.windowTitle(pid: front.pid, limits: limits) ?? title }
        // Any key, click or scroll in the last second. No event tap: only how long ago the last one was.
        let input = CGEventType(rawValue: ~0).map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) < 1.2 } ?? false
        beat(locked: isLocked, input: input)
    }

    /// One beat, with what was observed: tell the reducer, note the app in front, write what is due.
    private func beat(locked isLocked: Bool, input: Bool) {
        guard !stopped else { return }
        let now = now()
        if isLocked != locked { locked = isLocked; apply(.locked(isLocked, now: now)) }
        apply(.frontmost(front, window: title, now: now))
        if input { apply(.input(now: now)) }
        apply(.tick(now: now))
        // Which app is in front goes into the day only while that window may be read: the reducer has just
        // judged this app and this title, so a denied app or a private window leaves no trace, not even its name.
        if watch.mode == .watching, let front {
            journal?.note(app: front.name, bundleID: front.bundleID, category: front.bundleID.flatMap { categories[$0] ?? nil },
                          window: title, meetingID: route.currentMeeting, at: Date(timeIntervalSinceReferenceDate: now))
            if announced != front {
                announced = front
                let callback = onApp
                DispatchQueue.main.async { callback?(front) }
            }
        } else {
            journal?.endUsage()
        }
        // Which app is off limits, so the person can be shown it and change their mind.
        var offLimits: String?
        if case .hidden = watch.mode, let id = front?.bundleID, ScreenPrivacy.isDenied(id, list: denied) { offLimits = id }
        if offLimits != hidden {
            hidden = offLimits
            let callback = onHiddenApp
            DispatchQueue.main.async { callback?(offLimits) }
        }
        flushDay(now)
    }

    private func apply(_ event: ScreenWatch.Event) {
        for effect in watch.handle(event) {
            switch effect {
            case .read(let token, let app, _):
                let never = denied
                Task.detached(priority: .utility) { [weak self] in
                    guard let self else { return }
                    let reading = if let custom = self.reader { await custom(app, never) } else { await self.read(app, denied: never) }
                    self.queue.async { self.apply(reading.map { .read(token: token, $0) } ?? .readFailed(token: token)) }
                }
            case .keep(let reading): keep(reading)
            case .close(let at):
                let when = Date(timeIntervalSinceReferenceDate: at)
                if var sink = meeting { sink.builder.close(at: sink.timeline.seconds(when)); meeting = sink; persistMeeting() }
                journal?.endMoment(at: when)
                ScreenContext.shared.clear()
                flushDay(at, force: true)
            case .mode(let mode):
                switch mode {
                case .off: publish(.off)
                case .watching: publish(.recording)
                case .paused: publish(.paused)
                case .locked: publish(.privateApp("the lock screen"))
                case .hidden(let what): publish(.privateApp(what))
                }
            }
        }
    }

    private func keep(_ reading: ScreenWatch.Reading) {
        let when = Date(timeIntervalSinceReferenceDate: reading.at)
        var observation = ScreenObservation(time: 0, text: reading.text, lines: reading.lines, app: reading.app.name,
                                            bundleID: reading.app.bundleID, window: reading.window, url: reading.url, source: reading.source,
                                            embedding: reading.vector, embeddingModelID: reading.vectorModelID)
        switch route.home(at: reading.at) {
        case .meeting(let id):
            guard var sink = meeting, sink.id == id else { return }
            observation.time = sink.timeline.seconds(when)
            let before = (sink.builder.open?.id, sink.builder.open?.text, sink.builder.open?.embedding == nil)
            sink.builder.add(observation)
            sink.kept += 1
            if let open = sink.builder.open {
                ScreenContext.shared.publish(ScreenSnapshot(text: open.text, capturedAt: when, app: open.app, window: open.window,
                                                            meetingID: id, meetingSeconds: observation.time))
            }
            let open = sink.builder.open
            meeting = sink
            // Save when a stretch starts or its text grows; an unchanged window only moves its end, which the next save carries.
            if before.0 != open?.id || before.1 != open?.text || before.2 != (open?.embedding == nil) || sink.kept % 10 == 0 { persistMeeting() }
        case .day:
            journal?.keep(observation, at: when)
            ScreenContext.shared.publish(ScreenSnapshot(text: reading.text, capturedAt: when, app: reading.app.name, window: reading.window))
        case .nowhere:
            break
        }
    }

    private func persistMeeting() {
        guard let sink = meeting else { return }
        let moments = sink.moments
        guard sink.timeline.save(moments) else { return }
        let callback = onMeetingMoments, id = sink.id
        DispatchQueue.main.async { callback?(id, moments) }
    }

    /// Writes what the day's journal has to write (it decides how often), and says so.
    private func flushDay(_ now: Double, force: Bool = false) {
        guard journal != nil, let flushed = try? journal!.flush(now: Date(timeIntervalSinceReferenceDate: now), force: force), flushed.wrote else { return }
        notifyDay()
        if flushed.ended > 0 {
            let callback = onDayMomentEnded
            DispatchQueue.main.async { callback?() }
        }
    }

    private func notifyDay() {
        guard let journal else { return }
        let day = journal.current
        let totals = day.byApp(), count = journal.momentCount
        let callback = onDay
        DispatchQueue.main.async { callback?(totals, count, day.start, day.usage) }
    }

    private func publish(_ state: ScreenCaptureState) {
        let callback = onState
        DispatchQueue.main.async { callback?(state) }
    }

    private func info(state: String) -> ScreenCaptureInfo {
        ScreenCaptureInfo(file: nil, offset: nil, target: "window", state: state, failure: failure,
                          momentCount: (meeting?.earlier.count ?? 0) + (meeting?.builder.all.count ?? 0))
    }

    // MARK: For tests

    /// Starts without the Mac's permission, its timer or its notifications: the test supplies every beat.
    func startWithoutTheScreen() { queue.sync { apply(.start(now: now())) } }
    /// One beat with this app and window in front.
    func beat(front app: ScreenWatch.App?, title window: String?, locked: Bool = false, input: Bool = false) {
        queue.sync { front = app; title = window; beat(locked: locked, input: input) }
    }
    /// Returns once everything queued so far (a read coming back, say) has been handled.
    func settled() { queue.sync {} }

    // MARK: Reading one window (off the queue)

    /// Text first; a picture only when the window shows too little text of its own.
    private func read(_ app: ScreenWatch.App, denied: [String]) async -> ScreenWatch.Reading? {
        // The reducer never asks for a denied app. The reader would not read one if it did.
        guard !ScreenPrivacy.isDenied(app.bundleID, list: denied) else { return nil }
        let at = now()
        let text = ScreenReader.accessibilityText(pid: app.pid, limits: limits)
        let title = text?.title ?? ScreenReader.windowTitle(pid: app.pid, limits: limits)
        func reading(_ body: String, lines: [ScreenTextLine]? = nil, source: String, vector: [Float]? = nil) -> ScreenWatch.Reading {
            .init(app: app, window: title, text: body, lines: lines, source: source, url: text?.url, at: at,
                  vector: vector, vectorModelID: vector == nil ? nil : embedder?.modelID)
        }
        // Not even a picture is taken of a window that says it is private, or while the Mac is busy.
        let mayLook = !ScreenPrivacy.isPrivateWindow(title) && ScreenInferenceAdmission.shared.allowsOCR
        let words = ScreenMomentBuilder.words(text?.text ?? "").count
        if words >= limits.thinWords, let text {
            // The words are enough to read. What the window looks like is worth one picture per window, so it
            // can also be found by meaning ("the slide with the funnel chart"); the picture is not kept.
            // The words never wait long for the picture's vector: the vision model can take a minute to load,
            // and a reading that comes back after the person has moved on is dropped whole. A vector that
            // was not ready in time is picked up here by the next look at the same window.
            var vector = mayLook ? pictures.lateVector(pid: app.pid, title: title, at: at) : nil
            if vector == nil, let embedder, mayLook, ScreenInferenceAdmission.shared.allowsExtraPictures, pictures.wantsVector(pid: app.pid, title: title, at: at),
               let image = await ScreenReader.picture(pid: app.pid, title: title, limits: limits) {
                vector = await pictures.vector(for: image, pid: app.pid, title: title, at: at, embedder: embedder, wait: limits.vectorWait)
            }
            return reading(text.text, source: "accessibility", vector: vector)
        }
        guard mayLook, let image = await ScreenReader.picture(pid: app.pid, title: title, limits: limits) else {
            return text.map { reading($0.text, source: "accessibility") } ?? (title == nil ? nil : reading("", source: "accessibility"))
        }
        let seen = await pictures.text(for: image, pid: app.pid)
        var vector: [Float]?
        if let embedder { vector = await pictures.vector(for: image, pid: app.pid, title: title, at: at, embedder: embedder, wait: limits.vectorWait) }
        // Whichever says more. Controls an app exposes plus the words it draws rarely overlap usefully.
        if ScreenMomentBuilder.words(seen.text).count >= words { return reading(seen.text, lines: seen.lines, source: "ocr", vector: vector) }
        return reading(text?.text ?? "", source: "accessibility", vector: vector)
    }

    /// The last picture read per app, so an unchanged window is not read by Vision again.
    private final class PictureMemory: @unchecked Sendable {
        private let lock = NSLock()
        private var last: [pid_t: (signature: FrameSignature, text: String, lines: [ScreenTextLine])] = [:]
        private let detector = FrameChangeDetector()
        func text(for image: CGImage, pid: pid_t) async -> (text: String, lines: [ScreenTextLine]) {
            let signature = FrameSignature(image: image)
            if let signature, let known = lock.withLock({ last[pid] }), !detector.isMeaningful(from: known.signature, to: signature) {
                return (known.text, known.lines)
            }
            let read = await ScreenOCR.read(image)
            if let signature { lock.withLock { if last.count > 16 { last.removeAll() }; last[pid] = (signature, read.text, read.lines) } }
            return read
        }
        func clear() { lock.withLock { last.removeAll(); embedded.removeAll() }; late.clear() }

        /// The last picture embedded per app: its window, when, and the vector.
        private var embedded: [pid_t: (title: String?, at: Double, signature: FrameSignature?, vector: [Float])] = [:]
        /// A window whose words are read from accessibility gets one picture when it comes up, and another only
        /// after a minute in the same window.
        func wantsVector(pid: pid_t, title: String?, at: Double) -> Bool {
            // One picture of an app is embedded at a time; its vector is waited for, not asked for again.
            guard !late.isRunning(slot: pid) else { return false }
            return lock.withLock { embedded[pid].map { $0.title != title || at - $0.at >= 60 } ?? true }
        }
        /// Vectors still being worked out when the look that asked for them had to go on without them.
        private let late = LateResults<[Float]>()
        /// A vector for this window that came after the look that asked for it had gone on. Handed out once.
        func lateVector(pid: pid_t, title: String?, at: Double) -> [Float]? { late.late(slot: pid, tag: title, at: at, maxAge: 60) }
        /// The image embedding of `image`, when it is ready within `wait` seconds; otherwise nil now, and the
        /// vector later through `lateVector`. A picture that has not changed meaningfully reuses the last vector.
        func vector(for image: CGImage, pid: pid_t, title: String?, at: Double, embedder: CoreMLEmbedder, wait: Double) async -> [Float]? {
            let signature = FrameSignature(image: image)
            if let signature, let known = lock.withLock({ embedded[pid] }), let before = known.signature,
               !detector.isMeaningful(from: before, to: signature) {
                lock.withLock { embedded[pid] = (title, at, before, known.vector) }
                return known.vector
            }
            if let ready = late.late(slot: pid, tag: title, at: at, maxAge: 60) { return ready }
            return await late.run(slot: pid, tag: title, at: at, wait: wait) { [self] in
                guard let vector = try? await embedder.image(image) else { return nil }
                lock.withLock { if embedded.count > 16 { embedded.removeAll() }; embedded[pid] = (title, at, signature, vector) }
                return vector
            }
        }
    }
}

/// Whether a picture may be read right now: not while recognition is behind or the Mac is hot.
final class ScreenInferenceAdmission: @unchecked Sendable {
    static let shared = ScreenInferenceAdmission()
    private let lock = NSLock()
    private var pressure: RecordingPressure = .normal
    func set(_ value: RecordingPressure) { lock.withLock { pressure = value } }
    var allowsOCR: Bool { lock.withLock { pressure == .normal && ProcessInfo.processInfo.thermalState.rawValue <= ProcessInfo.ThermalState.fair.rawValue } }
    /// A picture of a window whose words can already be read is a nicety (it makes the window findable by
    /// what it looks like). Reading goes on all day, so it is skipped in Low Power Mode.
    var allowsExtraPictures: Bool { !ProcessInfo.processInfo.isLowPowerModeEnabled }
}
