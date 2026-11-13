import XCTest
@testable import WorkScribeCore

/// `ScreenWatch` against `formal/tla/ScreenWatch.tla`: the scripted tests walk the model's actions on
/// the real reducer (and the timing rules the model leaves out); the last test plays the model's
/// environment in random orders and checks its properties after every step.
final class ScreenWatchTests: XCTestCase {
    private let mail = ScreenWatch.App(name: "Mail", bundleID: "com.apple.mail", pid: 10)
    private let browser = ScreenWatch.App(name: "Safari", bundleID: "com.apple.Safari", pid: 20)
    private let vault = ScreenWatch.App(name: "1Password", bundleID: "com.1password.1password", pid: 30)

    private func reads(_ effects: [ScreenWatch.Effect]) -> [(token: Int, app: ScreenWatch.App, trigger: ScreenWatch.Trigger)] {
        effects.compactMap { if case .read(let token, let app, let trigger) = $0 { return (token, app, trigger) }; return nil }
    }
    private func kept(_ effects: [ScreenWatch.Effect]) -> [ScreenWatch.Reading] {
        effects.compactMap { if case .keep(let reading) = $0 { return reading }; return nil }
    }
    private func reading(_ app: ScreenWatch.App, window: String? = "Inbox", at: Double) -> ScreenWatch.Reading {
        .init(app: app, window: window, text: "Quarterly plan and the three open questions", source: "accessibility", at: at)
    }
    /// Started, with `app` in front, and the first read asked for. Returns its token.
    private func watching(_ watch: inout ScreenWatch, _ app: ScreenWatch.App, window: String? = "Inbox") -> Int {
        _ = watch.handle(.start(now: 0)); _ = watch.handle(.frontmost(app, window: window, now: 0))
        return reads(watch.handle(.tick(now: 1)))[0].token
    }

    // MARK: Timing (left out of the model)

    func testAChangeIsReadOnceItSettles() {
        var watch = ScreenWatch()
        XCTAssertTrue(reads(watch.handle(.start(now: 0))).isEmpty)
        XCTAssertTrue(reads(watch.handle(.frontmost(mail, window: "Inbox", now: 0))).isEmpty, "not before it settles")
        XCTAssertTrue(reads(watch.handle(.tick(now: 0.5))).isEmpty)
        let asked = reads(watch.handle(.tick(now: 0.9)))
        XCTAssertEqual(asked.map(\.app), [mail]); XCTAssertEqual(asked[0].trigger, .appSwitch)
        XCTAssertTrue(reads(watch.handle(.tick(now: 1.0))).isEmpty, "one read at a time")
        XCTAssertEqual(kept(watch.handle(.read(token: asked[0].token, reading(mail, at: 1)))).count, 1)
        XCTAssertTrue(reads(watch.handle(.tick(now: 5))).isEmpty, "nothing changed: wait for the idle interval")
        XCTAssertEqual(reads(watch.handle(.tick(now: 21))).first?.trigger, .idle)
    }

    func testTypingWithoutPauseIsStillReadWithinTheMaximumWait() {
        var watch = ScreenWatch()
        var token = watching(&watch, mail)
        _ = watch.handle(.read(token: token, reading(mail, at: 1)))
        var asked: [Double] = []
        // A keystroke every 0.3 s for a minute: never 0.8 s of quiet.
        for step in 0..<200 {
            let now = 2 + Double(step) * 0.3
            _ = watch.handle(.input(now: now))
            for read in reads(watch.handle(.tick(now: now))) { asked.append(now); token = read.token; _ = watch.handle(.read(token: token, reading(mail, at: now))) }
        }
        XCTAssertGreaterThanOrEqual(asked.count, 8, "read about every \(watch.settings.maximumWait) s")
        for (earlier, later) in zip(asked, asked.dropFirst()) {
            // The wait counts from the first keystroke after a read, and is noticed on the next tick.
            XCTAssertLessThanOrEqual(later - earlier, watch.settings.maximumWait + 0.7)
            XCTAssertGreaterThanOrEqual(later - earlier, watch.settings.minimumGap)
        }
    }

    func testAReadThatNeverReturnsIsGivenUpOnAndItsLateAnswerDropped() {
        var watch = ScreenWatch()
        let token = watching(&watch, mail)
        XCTAssertTrue(reads(watch.handle(.tick(now: 5))).isEmpty, "still waiting")
        let again = reads(watch.handle(.tick(now: 30)))
        XCTAssertEqual(again.count, 1); XCTAssertNotEqual(again[0].token, token)
        XCTAssertTrue(kept(watch.handle(.read(token: token, reading(mail, at: 31)))).isEmpty, "the late answer is stale")
        XCTAssertEqual(kept(watch.handle(.read(token: again[0].token, reading(mail, at: 31)))).count, 1)
    }

    // MARK: The model's actions

    func testNothingIsAskedOfADeniedAppAndTheStretchEnds() {
        var watch = ScreenWatch()
        let token = watching(&watch, mail)
        _ = watch.handle(.read(token: token, reading(mail, at: 1)))
        let switched = watch.handle(.frontmost(vault, window: "Vault", now: 3))
        XCTAssertTrue(switched.contains(.close(at: 3))); XCTAssertTrue(switched.contains(.mode(.hidden("1Password"))))
        for now in stride(from: 4.0, to: 60, by: 1) { XCTAssertTrue(reads(watch.handle(.tick(now: now))).isEmpty) }
        _ = watch.handle(.frontmost(mail, window: "Inbox", now: 61))
        XCTAssertEqual(reads(watch.handle(.tick(now: 62))).first?.app, mail)
    }

    func testAReadAskedBeforeAnAppSwitchIsDropped() {
        var watch = ScreenWatch()
        let token = watching(&watch, mail)
        _ = watch.handle(.frontmost(browser, window: "News", now: 1.2))
        XCTAssertTrue(kept(watch.handle(.read(token: token, reading(mail, at: 1.3)))).isEmpty)
    }

    func testAPrivateWindowFoundByReadingBeforeItsNotificationIsNotKept() {
        var watch = ScreenWatch()
        let token = watching(&watch, browser, window: "News")
        // The person opened a private window; the reader got there before the title-change notification.
        let effects = watch.handle(.read(token: token, reading(browser, window: "Private Browsing — Bank", at: 1.4)))
        XCTAssertTrue(kept(effects).isEmpty); XCTAssertTrue(effects.contains(.close(at: 1.4)))
        XCTAssertEqual(watch.mode, .hidden("a private window"))
        for now in stride(from: 2.0, to: 40, by: 1) { XCTAssertTrue(reads(watch.handle(.tick(now: now))).isEmpty) }
        _ = watch.handle(.frontmost(browser, window: "News", now: 41))
        XCTAssertEqual(reads(watch.handle(.tick(now: 42))).count, 1, "back in an ordinary window")
    }

    func testPauseLockAndStopDropWhatWasBeingReadEvenAfterResuming() {
        for shut in ["pause", "lock", "stop"] {
            var watch = ScreenWatch()
            let token = watching(&watch, mail)
            let closing: [ScreenWatch.Effect]
            switch shut {
            case "pause": closing = watch.handle(.paused(true, now: 1.2))
            case "lock": closing = watch.handle(.locked(true, now: 1.2))
            default: closing = watch.handle(.stop(now: 1.2))
            }
            XCTAssertTrue(closing.contains(.close(at: 1.2)), shut)
            XCTAssertTrue(kept(watch.handle(.read(token: token, reading(mail, at: 1.3)))).isEmpty, shut)
            for now in stride(from: 2.0, to: 30, by: 1) { XCTAssertTrue(reads(watch.handle(.tick(now: now))).isEmpty, shut) }
            switch shut {
            case "pause": _ = watch.handle(.paused(false, now: 31))
            case "lock": _ = watch.handle(.locked(false, now: 31))
            default: _ = watch.handle(.start(now: 31))
            }
            // The read from before must not be accepted now that the gate is open again.
            XCTAssertTrue(kept(watch.handle(.read(token: token, reading(mail, at: 31.1)))).isEmpty, shut)
            XCTAssertEqual(reads(watch.handle(.tick(now: 32))).count, 1, shut)
        }
    }

    func testPrivateWindowTitles() {
        for title in ["Private Browsing — Start Page", "Bank - Google Chrome (Incognito)", "New InPrivate tab - Microsoft Edge", "Mozilla Firefox Private Browsing", "New Private Window"] {
            XCTAssertTrue(ScreenPrivacy.isPrivateWindow(title), title)
        }
        for title in ["Inbox", "Privacy policy - Docs", "Incognito mode explained - Wikipedia", nil, ""] {
            XCTAssertFalse(ScreenPrivacy.isPrivateWindow(title), title ?? "nil")
        }
    }

    // MARK: The model's environment, in random order

    private struct Random: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 11 ^ state }
        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    }

    func testRandomOrdersKeepTheModelsProperties() {
        let apps = [mail, browser, vault]
        var keptCount = 0, droppedStale = 0, foundPrivateByReading = 0
        for seed in 1...3_000 {
            var random = Random(state: UInt64(seed) &* 0x9E3779B97F4A7C15)
            var watch = ScreenWatch()
            // The world, and the reducer's knowledge of it lagging behind through `notes`.
            var front = apps[random.below(2)], privateWindow = [Int32: Bool](), worldLocked = false
            var notes: [ScreenWatch.Event] = []
            var now = 0.0
            var running = false, paused = false, lockedView = false
            var asked: [(token: Int, app: ScreenWatch.App, openWhenAsked: Bool)] = []
            var results: [(token: Int, reading: ScreenWatch.Reading, readOpen: Bool, fromDenied: Bool)] = []
            var outstanding = 0
            func title(_ app: ScreenWatch.App) -> String { privateWindow[app.pid] == true ? "Private Browsing — Bank" : "Notes" }
            func note(_ app: ScreenWatch.App) { notes.append(.frontmost(app, window: title(app), now: 0)) }
            func open() -> Bool { running && !paused && !lockedView }
            func apply(_ event: ScreenWatch.Event) {
                for effect in watch.handle(event) {
                    switch effect {
                    case .read(let token, let app, _):
                        XCTAssertTrue(open(), "seed \(seed): a read was asked for while shut")
                        XCTAssertFalse(ScreenPrivacy.isDenied(app.bundleID), "seed \(seed): a denied app was asked for")
                        asked.append((token, app, open())); outstanding += 1
                    case .keep(let reading):
                        keptCount += 1
                        XCTAssertTrue(open(), "seed \(seed): kept while shut")
                        XCTAssertFalse(ScreenPrivacy.isDenied(reading.app.bundleID), "seed \(seed): kept a denied app's text")
                        XCTAssertFalse(ScreenPrivacy.isPrivateWindow(reading.window), "seed \(seed): kept a private window's text")
                        XCTAssertFalse(reading.text.hasPrefix("SHUT"), "seed \(seed): kept text read while capture was shut")
                    default: break
                    }
                }
            }
            note(front)
            for _ in 0..<400 {
                now += Double(random.below(12)) / 10
                switch random.below(30) {
                case 0: front = apps[random.below(3)]; note(front)                                   // SwitchApp
                case 1: privateWindow[front.pid] = !(privateWindow[front.pid] ?? false); note(front)   // TogglePrivate
                case 2: if random.below(3) == 0 { worldLocked.toggle(); notes.append(.locked(worldLocked, now: 0)) }
                case 3: if random.below(2) == 0 { running.toggle(); apply(running ? .start(now: now) : .stop(now: now)) }
                case 4: if random.below(2) == 0 { paused.toggle(); apply(.paused(paused, now: now)) }
                case 5...8:                                                                            // Notice
                    guard !notes.isEmpty else { break }
                    switch notes.removeFirst() {
                    case .frontmost(let app, let window, _): apply(.frontmost(app, window: window, now: now))
                    case .locked(let value, _): lockedView = value; apply(.locked(value, now: now))
                    default: break
                    }
                case 9...13:                                                                           // Perform
                    guard !asked.isEmpty else { break }
                    let request = asked.remove(at: random.below(asked.count))
                    // The reader reads that app's window as it is now, and says so.
                    let text = (open() ? "" : "SHUT ") + "plan review notes for the quarter"
                    results.append((request.token, .init(app: request.app, window: title(request.app), text: text, source: "accessibility", at: now), open(), false))
                case 14...18:                                                                          // Return
                    guard !results.isEmpty else { break }
                    let result = results.remove(at: random.below(results.count))
                    let before = watch.mode
                    apply(.read(token: result.token, result.reading))
                    if ScreenPrivacy.isPrivateWindow(result.reading.window), before == .watching, watch.mode != .watching { foundPrivateByReading += 1 }
                case 19: if !asked.isEmpty, random.below(4) == 0 { asked.removeFirst(); droppedStale += 1 }   // Lose
                case 20: apply(.input(now: now))
                default: apply(.tick(now: now))
                }
            }
        }
        // The runs must reach what the properties are about.
        XCTAssertGreaterThan(keptCount, 1_000, "readings kept")
        XCTAssertGreaterThan(foundPrivateByReading, 20, "private windows found by the reader before their notification")
        XCTAssertGreaterThan(droppedStale, 100, "reads that never came back")
    }
}
