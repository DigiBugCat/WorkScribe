import XCTest
import WorkScribeCore
@testable import WorkScribe

/// The real `ScreenWatcher` (its queue, the reducer, the day journal and the meeting timeline) driven beat by beat,
/// with a stand-in for the one thing a test cannot do: read a window. Time is moved by hand.
final class ScreenWatcherTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date().timeIntervalSinceReferenceDate
        var now: Double { lock.withLock { value } }
        func advance(_ seconds: Double) { lock.withLock { value += seconds } }
    }
    /// What each app's window shows right now.
    private final class Windows: @unchecked Sendable {
        private let lock = NSLock()
        private var text: [Int32: (title: String, text: String)] = [:]
        private(set) var reads: [String] = []
        func show(_ pid: Int32, _ title: String, _ words: String) { lock.withLock { text[pid] = (title, words) } }
        func read(_ app: ScreenWatch.App, at: Double) -> ScreenWatch.Reading? {
            lock.withLock {
                reads.append(app.bundleID ?? "")
                return text[app.pid].map { .init(app: app, window: $0.title, text: $0.text, source: "accessibility", at: at) }
            }
        }
        var readApps: [String] { lock.withLock { reads } }
    }

    private var root: URL!
    private let clock = Clock()
    private let windows = Windows()
    private let xcode = ScreenWatch.App(name: "Xcode", bundleID: "com.apple.dt.Xcode", pid: 100)
    private let safari = ScreenWatch.App(name: "Safari", bundleID: "com.apple.Safari", pid: 200)
    private let vault = ScreenWatch.App(name: "1Password", bundleID: "com.1password.1password", pid: 300)

    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("watcher-" + UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func watcher(keepingDay: Bool) -> (ScreenWatcher, MeetingStore, ScreenDayStore) {
        let store = MeetingStore(root: root)
        let days = ScreenDayStore(meetings: store)
        let watcher = ScreenWatcher(dayStore: keepingDay ? days : nil, embedder: nil)
        let clock = clock, windows = windows
        watcher.clock = { clock.now }
        watcher.reader = { app, _ in windows.read(app, at: clock.now) }
        watcher.startWithoutTheScreen()
        return (watcher, store, days)
    }

    /// `seconds` of one-second beats with `app` in front, giving each read time to come back.
    private func spend(_ seconds: Int, in app: ScreenWatch.App?, title: String?, on watcher: ScreenWatcher) async {
        for _ in 0..<seconds {
            clock.advance(1)
            watcher.beat(front: app, title: title)
            // A read runs off the watcher's queue and reports back onto it.
            try? await Task.sleep(nanoseconds: 15_000_000)
            watcher.settled()
        }
    }
    private var today: String { ScreenDayStore.day(Date(timeIntervalSinceReferenceDate: clock.now)).id }

    func testADayOfWindowsIsKeptByApplication() async throws {
        let (watcher, _, days) = watcher(keepingDay: true)
        windows.show(100, "AppModel.swift", "func start() async throws begins the recording and claims the slot")
        windows.show(200, "Swift concurrency — Docs", "Actors protect their mutable state from data races between tasks")
        await spend(6, in: xcode, title: "AppModel.swift", on: watcher)
        await spend(6, in: safari, title: "Swift concurrency — Docs", on: watcher)
        await spend(4, in: xcode, title: "AppModel.swift", on: watcher)
        await watcher.stop()

        let day = try XCTUnwrap(days.load(today))
        XCTAssertEqual(day.moments.map(\.app), ["Xcode", "Safari", "Xcode"])
        XCTAssertEqual(day.moments[1].window, "Swift concurrency — Docs")
        XCTAssertTrue(day.moments[0].text.contains("claims the slot"))
        let totals = day.byApp()
        XCTAssertEqual(Set(totals.map(\.app)), ["Xcode", "Safari"])
        XCTAssertEqual(totals.first { $0.app == "Xcode" }?.spans, 2)
        XCTAssertEqual(totals.first { $0.app == "Safari" }?.windows, ["Swift concurrency — Docs"])
        for moment in day.moments { XCTAssertLessThanOrEqual(moment.start, moment.end) }
    }

    func testAnAppThatIsNeverReadLeavesNoTraceNotEvenItsName() async throws {
        let (watcher, _, days) = watcher(keepingDay: true)
        windows.show(100, "Notes.swift", "ordinary work that may be read and kept in the journal")
        windows.show(300, "Vault", "the master password and every secret in the vault")
        await spend(5, in: xcode, title: "Notes.swift", on: watcher)
        await spend(6, in: vault, title: "Vault", on: watcher)
        await spend(4, in: xcode, title: "Notes.swift", on: watcher)
        await watcher.stop()

        let day = try XCTUnwrap(days.load(today))
        XCTAssertFalse(windows.readApps.contains("com.1password.1password"), "its window was never even read")
        XCTAssertEqual(Set(day.moments.compactMap(\.app)), ["Xcode"])
        XCTAssertEqual(Set(day.usage.map(\.app)), ["Xcode"])
        let log = try String(contentsOf: root.appendingPathComponent(".screen/\(today).jsonl"), encoding: .utf8)
        XCTAssertFalse(log.contains("1Password")); XCTAssertFalse(log.contains("Vault")); XCTAssertFalse(log.contains("master password"))
    }

    func testAPrivateBrowserWindowIsNotReadOrNamed() async throws {
        let (watcher, _, days) = watcher(keepingDay: true)
        windows.show(200, "Bank login — Private Browsing", "account number and the balance of the account")
        await spend(6, in: safari, title: "Bank login — Private Browsing", on: watcher)
        await watcher.stop()
        XCTAssertNil(days.load(today), "nothing at all was written")
        XCTAssertTrue(windows.readApps.isEmpty)
    }

    func testWhatIsReadDuringARecordingBelongsToTheMeetingAndTheRestToTheDay() async throws {
        let (watcher, store, days) = watcher(keepingDay: true)
        var meeting = Meeting(title: "Planning"); meeting.startedAt = Date(timeIntervalSinceReferenceDate: clock.now + 6)
        try store.save(meeting)
        windows.show(100, "Before.swift", "what was on screen before the call began this morning")
        await spend(6, in: xcode, title: "Before.swift", on: watcher)

        let begun = await watcher.beginMeeting(id: meeting.id, timeline: MeetingScreenTimeline(store: store, meetingID: meeting.id, start: meeting.startedAt))
        windows.show(100, "Roadmap.key", "the roadmap slide shown to everyone during the planning call")
        await spend(6, in: xcode, title: "Roadmap.key", on: watcher)
        let ended = await watcher.endMeeting(begun.token)

        windows.show(100, "After.swift", "back to ordinary work once the call had ended")
        await spend(6, in: xcode, title: "After.swift", on: watcher)
        await watcher.stop()

        let inMeeting = try XCTUnwrap(ended).moments
        XCTAssertEqual(inMeeting.map(\.window), ["Roadmap.key"])
        XCTAssertGreaterThanOrEqual(inMeeting[0].start, 0, "on the meeting's own clock")
        XCTAssertEqual(store.loadScreenMoments(meeting.id).map(\.window), ["Roadmap.key"])

        let day = try XCTUnwrap(days.load(today))
        XCTAssertEqual(day.moments.map(\.window), ["Before.swift", "After.swift"], "the day keeps nothing that was read during the recording")
        XCTAssertFalse(try String(contentsOf: root.appendingPathComponent(".screen/\(today).jsonl"), encoding: .utf8).contains("roadmap slide"))
        // The day still knows which app was in front during the meeting, and that it was a meeting.
        XCTAssertTrue(day.usage.contains { $0.meetingID == meeting.id && $0.windows == ["Roadmap.key"] })
        XCTAssertTrue(day.usage.contains { $0.meetingID == nil && $0.windows.contains("After.swift") })
    }

    /// Stop, then Resume before the stop's "end the meeting's screen" has had its turn: when it does arrive, it
    /// must not end the resumed stretch, or the rest of the meeting's screen would go to the day.
    func testAStopThatArrivesAfterAResumeDoesNotSendTheMeetingsScreenToTheDay() async throws {
        let (watcher, store, days) = watcher(keepingDay: true)
        var meeting = Meeting(title: "Resumed"); meeting.startedAt = Date(timeIntervalSinceReferenceDate: clock.now)
        try store.save(meeting)
        let timeline = MeetingScreenTimeline(store: store, meetingID: meeting.id, start: meeting.startedAt)
        let first = await watcher.beginMeeting(id: meeting.id, timeline: timeline)
        windows.show(100, "First.key", "what was shown in the first part of the meeting")
        await spend(6, in: xcode, title: "First.key", on: watcher)
        // Resumed: the meeting begins again under the same id. The first stop's end is still on its way.
        let second = await watcher.beginMeeting(id: meeting.id, timeline: timeline)
        let late = await watcher.endMeeting(first.token)
        XCTAssertNil(late, "the late stop ends nothing")
        windows.show(100, "Second.key", "what was shown after the meeting was resumed")
        await spend(6, in: xcode, title: "Second.key", on: watcher)
        let ended = await watcher.endMeeting(second.token)
        await watcher.stop()
        XCTAssertEqual(ended?.moments.map(\.window), ["First.key", "Second.key"], "both parts are the meeting's")
        XCTAssertTrue(days.load(today)?.moments.isEmpty ?? true, "and none of it reached the day")
    }

    func testWithoutAllDayReadingOnlyTheMeetingIsKept() async throws {
        let (watcher, store, days) = watcher(keepingDay: false)
        windows.show(100, "Before.swift", "text on screen while no meeting is being recorded at all")
        await spend(5, in: xcode, title: "Before.swift", on: watcher)
        var meeting = Meeting(title: "Call"); meeting.startedAt = Date(timeIntervalSinceReferenceDate: clock.now)
        try store.save(meeting)
        _ = await watcher.beginMeeting(id: meeting.id, timeline: MeetingScreenTimeline(store: store, meetingID: meeting.id, start: meeting.startedAt))
        windows.show(100, "Slides.key", "the slide that is being presented during this call")
        await spend(5, in: xcode, title: "Slides.key", on: watcher)
        let ended = await watcher.stop()
        XCTAssertEqual(ended?.moments.map(\.window), ["Slides.key"])
        XCTAssertTrue(days.days().isEmpty, "no journal of the day exists")
    }

    func testPausingStopsBothTheReadingAndTheNoting() async throws {
        let (watcher, _, days) = watcher(keepingDay: true)
        windows.show(100, "Open.swift", "work that is read before the pause is asked for")
        await spend(5, in: xcode, title: "Open.swift", on: watcher)
        watcher.setPaused(true); watcher.settled()
        windows.show(100, "Secret.swift", "something opened only while reading was paused")
        let before = windows.readApps.count
        await spend(8, in: xcode, title: "Secret.swift", on: watcher)
        XCTAssertEqual(windows.readApps.count, before, "nothing is read while paused")
        // The person goes back to ordinary work, then resumes. (Resuming reads whatever is in front at that moment.)
        windows.show(100, "Open.swift", "work that is read again after reading resumed")
        await spend(2, in: xcode, title: "Open.swift", on: watcher)
        watcher.setPaused(false); watcher.settled()
        await spend(5, in: xcode, title: "Open.swift", on: watcher)
        await watcher.stop()
        let day = try XCTUnwrap(days.load(today))
        XCTAssertFalse(day.moments.contains { $0.window == "Secret.swift" })
        XCTAssertFalse(day.usage.contains { $0.windows.contains("Secret.swift") }, "not even the window's title")
        XCTAssertEqual(day.usage.count, 2, "the pause splits the app's time in two")
    }

    func testAnAppDeniedWhileItIsInFrontStopsBeingReadAtOnce() async throws {
        let (watcher, _, days) = watcher(keepingDay: true)
        windows.show(200, "Inbox", "mail that was readable until the person said never to read it")
        await spend(5, in: safari, title: "Inbox", on: watcher)
        watcher.setDenied(["com.apple.Safari"]); watcher.settled()
        let before = windows.readApps.count
        windows.show(200, "Inbox", "a later message that must never be read or kept")
        await spend(8, in: safari, title: "Inbox", on: watcher)
        await watcher.stop()
        XCTAssertEqual(windows.readApps.count, before)
        XCTAssertFalse(try String(contentsOf: root.appendingPathComponent(".screen/\(today).jsonl"), encoding: .utf8).contains("later message"))
        XCTAssertEqual(days.load(today)?.moments.count, 1)
    }
}
