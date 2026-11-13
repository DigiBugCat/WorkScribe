import Foundation

/// When to look at the screen, and whether what was read may be kept.
///
/// Capture is driven by events, not by a stream of frames: the frontmost app or its window
/// changes, the person types or clicks and then pauses, or nothing has happened for a while. Each
/// look reads ONE app's focused window (its accessibility text, or a picture of that window when
/// there is too little text), never "whatever is on screen". That is what makes the privacy rule
/// hold under delay: a look that was asked for while Safari was in front reads Safari's window even
/// if a password manager has come forward by the time it runs.
///
/// This type is the pure decision: `handle` takes one event and returns what to do. It owns no
/// timers, no windows and no clock. The design is checked in `formal/tla/ScreenWatch.tla`; each case
/// names the model action it implements. What the model guarantees, and this file must keep true:
///
///  - nothing read from a denied app or a private window is ever kept, whatever the order in which
///    the person's actions, their notifications and a slow read arrive;
///  - nothing is kept while capture is paused, the screen is locked, or capture has stopped, and a
///    read that was asked for before any of those is dropped when it returns;
///  - at most one read is in progress;
///  - while the person stays in a permitted window, a read keeps being asked for (typing without
///    pause cannot postpone it forever).
public struct ScreenWatch {
    public struct Settings: Equatable, Sendable {
        /// Quiet time after a change before looking: let the window finish drawing, the sentence finish.
        public var settle = 0.8
        /// The longest a change may wait for quiet. Continuous typing still gets read.
        public var maximumWait = 6.0
        /// Least time between the starts of two looks.
        public var minimumGap = 1.5
        /// With nothing happening, look again after this long (a video, a slide someone else advances).
        public var idleInterval = 20.0
        /// A look that has not come back after this long is given up on.
        public var readTimeout = 8.0
        public var deniedBundleIDs = ScreenPrivacy.defaultDeniedBundleIDs
        public init() {}
    }

    public struct App: Equatable, Sendable {
        public var name: String?
        public var bundleID: String?
        public var pid: Int32
        public init(name: String?, bundleID: String?, pid: Int32) { self.name = name; self.bundleID = bundleID; self.pid = pid }
    }

    public enum Trigger: String, Sendable { case start, appSwitch, windowChange, input, idle }

    /// What one look found. `app` and `window` are what was actually read, as the reader saw them.
    public struct Reading: Equatable, Sendable {
        public var app: App
        public var window: String?
        public var text: String
        public var lines: [ScreenTextLine]?
        /// "accessibility" or "ocr".
        public var source: String
        public var url: String?
        /// When the window was read, on the caller's clock.
        public var at: Double
        /// What the window looked like, as an image embedding, when a picture of it was taken. Carried through
        /// untouched: a reading that is dropped takes its vector with it.
        public var vector: [Float]?
        public var vectorModelID: String?
        public init(app: App, window: String?, text: String, lines: [ScreenTextLine]? = nil, source: String, url: String? = nil, at: Double,
                    vector: [Float]? = nil, vectorModelID: String? = nil) {
            self.app = app; self.window = window; self.text = text; self.lines = lines; self.source = source; self.url = url; self.at = at
            self.vector = vector; self.vectorModelID = vectorModelID
        }
    }

    public enum Event {
        case start(now: Double)
        case stop(now: Double)
        case paused(Bool, now: Double)
        /// The screen locked, the display slept, or the session was switched away.
        case locked(Bool, now: Double)
        /// The frontmost app, or its focused window's title, as last reported.
        case frontmost(App?, window: String?, now: Double)
        /// The person typed, clicked or scrolled.
        case input(now: Double)
        case tick(now: Double)
        case read(token: Int, Reading)
        case readFailed(token: Int)
    }

    public enum Mode: Equatable, Sendable {
        case off
        case watching
        case paused
        case locked
        /// A denied app, or a private window, is in front: nothing is read.
        case hidden(String)
    }

    public enum Effect: Equatable {
        /// Read this app's focused window and report it with `.read(token:)`.
        case read(token: Int, app: App, trigger: Trigger)
        /// A permitted reading: add it to the timeline.
        case keep(Reading)
        /// The current stretch of screen ended here (app changed, private window, pause, lock, stop).
        case close(at: Double)
        case mode(Mode)
    }

    public var settings: Settings
    public private(set) var mode = Mode.off
    private var running = false, paused = false, locked = false
    private var front: App?
    private var window: String?
    /// Bumped by anything that makes a read asked for earlier stale.
    private var epoch = 0
    private var reading: (token: Int, since: Double)?
    private var changedSince: Double?
    private var lastChange = -Double.infinity
    private var lastRead = -Double.infinity
    private var trigger = Trigger.start

    public init(settings: Settings = Settings()) { self.settings = settings }

    public mutating func handle(_ event: Event) -> [Effect] {
        var out: [Effect] = []
        switch event {
        case .start(let now):
            // TLA: Start
            guard !running else { break }
            running = true; epoch += 1; reading = nil; changedSince = nil
            changed(.start, now)
            ask(now, &out)
        case .stop(let now):
            // TLA: Stop
            guard running else { break }
            running = false; shut(now, &out)
        case .paused(let value, let now):
            // TLA: Pause / Resume
            guard paused != value else { break }
            paused = value
            if value { shut(now, &out) } else { epoch += 1; changed(.start, now); ask(now, &out) }
        case .locked(let value, let now):
            // TLA: Lock / Unlock
            guard locked != value else { break }
            locked = value
            if value { shut(now, &out) } else { epoch += 1; changed(.start, now); ask(now, &out) }
        case .frontmost(let app, let title, let now):
            // TLA: Notice. Whatever was being read belongs to the window that was in front before.
            guard app != front || title != window else { break }
            let appChanged = app?.pid != front?.pid
            front = app; window = title
            epoch += 1; reading = nil
            if open, appChanged || !permitted { out.append(.close(at: now)) }
            // A new app is a new change to wait out, however long the last one had been waiting.
            if appChanged { changedSince = nil }
            changed(appChanged ? .appSwitch : .windowChange, now)
            ask(now, &out)
        case .input(let now):
            // TLA: Input
            changed(.input, now)
        case .tick(let now):
            // TLA: Tick
            if let reading, now - reading.since >= settings.readTimeout { epoch += 1; self.reading = nil }
            ask(now, &out)
        case .read(let token, let result):
            // TLA: Return. The reading is judged by what it actually is, not by what was expected.
            guard let reading, reading.token == token else { break }
            self.reading = nil
            guard token == epoch, open, result.app.pid == front?.pid,
                  !ScreenPrivacy.isDenied(result.app.bundleID, list: settings.deniedBundleIDs) else { break }
            if ScreenPrivacy.isPrivateWindow(result.window) {
                // The window turned out to be a private one before its title change was reported.
                window = result.window; epoch += 1
                out.append(.close(at: result.at))
                break
            }
            out.append(.keep(result))
        case .readFailed(let token):
            if reading?.token == token { reading = nil }
        }
        let next = currentMode
        if next != mode { mode = next; out.append(.mode(next)) }
        return out
    }

    // MARK: The gate

    /// Capture is on and nothing global stops it.
    private var open: Bool { running && !paused && !locked }
    /// The window in front may be read.
    private var permitted: Bool {
        guard let front else { return false }
        return !ScreenPrivacy.isDenied(front.bundleID, list: settings.deniedBundleIDs) && !ScreenPrivacy.isPrivateWindow(window)
    }
    private var currentMode: Mode {
        guard running else { return .off }
        if paused { return .paused }
        if locked { return .locked }
        if let front, !permitted { return .hidden(ScreenPrivacy.isPrivateWindow(window) ? "a private window" : front.name ?? "a private app") }
        return .watching
    }

    /// Pause, lock, stop: whatever is being read is stale, and the timeline's current stretch ends.
    private mutating func shut(_ now: Double, _ out: inout [Effect]) {
        epoch += 1; reading = nil; changedSince = nil
        out.append(.close(at: now))
    }

    private mutating func changed(_ why: Trigger, _ now: Double) {
        if changedSince == nil { changedSince = now; trigger = why }
        lastChange = now
    }

    /// TLA: Ask. One read at a time, spaced out, once the change has settled or has waited long enough.
    private mutating func ask(_ now: Double, _ out: inout [Effect]) {
        guard open, permitted, reading == nil, let front, now - lastRead >= settings.minimumGap else { return }
        let why: Trigger
        if let since = changedSince {
            guard now - lastChange >= settings.settle || now - since >= settings.maximumWait else { return }
            why = trigger
        } else {
            guard now - lastRead >= settings.idleInterval else { return }
            why = .idle
        }
        changedSince = nil; lastRead = now
        reading = (epoch, now)
        out.append(.read(token: epoch, app: front, trigger: why))
    }
}

extension ScreenPrivacy {
    /// A browser's private window, by its title. A heuristic: browsers do not expose "private" as a
    /// fact, only in the title they choose to show, so a browser that shows nothing is not caught.
    public static func isPrivateWindow(_ title: String?) -> Bool {
        guard let title = title?.lowercased(), !title.isEmpty else { return false }
        return ["private browsing", "(incognito)", "- incognito", "— incognito", "inprivate", "(private)", "private window", "private tab"]
            .contains { title.contains($0) }
    }
}
