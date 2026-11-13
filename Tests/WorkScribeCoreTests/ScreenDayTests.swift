import XCTest
@testable import WorkScribeCore

/// All-day screen reading: the day journal, per-app usage, where a reading belongs, and the index.
final class ScreenDayTests: XCTestCase {
    private var root: URL!
    private var calendar: Calendar!
    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("screen-day-" + UUID().uuidString)
        calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute, second: second))!
    }
    private func observation(_ text: String, app: String = "Xcode", bundle: String? = "com.apple.dt.Xcode", window: String? = "AppModel.swift",
                             vector: [Float]? = nil) -> ScreenObservation {
        ScreenObservation(time: 0, text: text, app: app, bundleID: bundle, window: window, source: "accessibility",
                          embedding: vector, embeddingModelID: vector == nil ? nil : "model-a")
    }

    // MARK: App usage

    func testNotesOfOneAppBecomeOneSpanWithItsWindows() {
        var usage = AppUsageBuilder()
        for second in 0..<10 { usage.note(app: "Xcode", bundleID: "com.apple.dt.Xcode", window: second < 5 ? "A.swift" : "B.swift", at: Double(second)) }
        usage.note(app: "Safari", bundleID: "com.apple.Safari", category: "Browser", window: "Docs", at: 10)
        usage.note(app: "Safari", bundleID: "com.apple.Safari", category: "Browser", window: "Docs", at: 14)
        usage.close()
        XCTAssertEqual(usage.all.map(\.app), ["Xcode", "Safari"])
        XCTAssertEqual(usage.all[0].windows, ["A.swift", "B.swift"])
        XCTAssertEqual(usage.all[0].seconds, 9, accuracy: 0.01)
        XCTAssertEqual(usage.all[1].category, "Browser")
    }

    func testAGapASleepOrAMeetingBoundaryStartsANewSpan() {
        var usage = AppUsageBuilder()
        usage.note(app: "Xcode", bundleID: "x", at: 0); usage.note(app: "Xcode", bundleID: "x", at: 4)
        usage.note(app: "Xcode", bundleID: "x", at: 600)                         // the lid was closed for ten minutes
        usage.note(app: "Xcode", bundleID: "x", at: 604)
        usage.note(app: "Xcode", bundleID: "x", meetingID: "m1", at: 605)        // a recording began
        usage.note(app: "Xcode", bundleID: "x", meetingID: "m1", at: 609)
        usage.close()
        XCTAssertEqual(usage.all.map { [$0.start, $0.end] }, [[0, 4], [600, 604], [605, 609]])
        XCTAssertEqual(usage.all.map(\.meetingID), [nil, nil, "m1"])
    }

    func testPassingOverAnAppIsNotUse() {
        var usage = AppUsageBuilder()
        usage.note(app: "Finder", bundleID: "f", at: 0)
        for second in 0..<10 { usage.note(app: "Xcode", bundleID: "x", at: 0.4 + Double(second)) }
        usage.close()
        XCTAssertEqual(usage.all.map(\.app), ["Xcode"])
    }

    func testAnAppIsDescribedByWhatItIsKnownAsOrWhatItDeclares() {
        XCTAssertEqual(AppCategory.name(bundleID: "com.google.Chrome", declared: "public.app-category.productivity"), "Browser")
        XCTAssertEqual(AppCategory.name(bundleID: "com.google.Chrome.canary", declared: nil), "Browser")
        XCTAssertEqual(AppCategory.name(bundleID: "com.apple.dt.Xcode", declared: "public.app-category.developer-tools"), "Developer tools")
        XCTAssertEqual(AppCategory.name(bundleID: "com.example.game", declared: "public.app-category.puzzle-games"), "Games")
        XCTAssertEqual(AppCategory.name(bundleID: "com.example.x", declared: "public.app-category.something-new"), "Something new")
        XCTAssertNil(AppCategory.name(bundleID: "com.example.x", declared: nil))
    }

    // MARK: Where a reading belongs

    func testEveryReadingHasExactlyOneHome() {
        var route = ScreenRoute(keepsDay: true)
        XCTAssertEqual(route.home(at: 10), .day)
        route.begin(meeting: "m1", at: 100)
        XCTAssertEqual(route.home(at: 99), .day, "read before the recording began: the day's")
        XCTAssertEqual(route.home(at: 100), .meeting("m1"))
        XCTAssertEqual(route.home(at: 500), .meeting("m1"))
        route.endMeeting(at: 600)
        XCTAssertEqual(route.home(at: 599), .nowhere, "read during a meeting that has ended: its timeline is closed, and the day does not take it")
        XCTAssertEqual(route.home(at: 600), .day)
    }

    func testWithoutAllDayReadingNothingOutsideAMeetingIsKept() {
        var route = ScreenRoute(keepsDay: false)
        XCTAssertEqual(route.home(at: 10), .nowhere)
        route.begin(meeting: "m1", at: 100)
        XCTAssertEqual(route.home(at: 150), .meeting("m1"))
        route.endMeeting(at: 200)
        XCTAssertEqual(route.home(at: 250), .nowhere)
    }

    /// Random begins, ends and readings: a reading goes to a meeting only if that meeting was recording when it
    /// was read, and to the day only if no meeting was.
    func testRandomRoutesNeverCrossAMeetingBoundary() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            var route = ScreenRoute(keepsDay: true)
            var intervals: [(id: String, from: Double, to: Double?)] = []
            var now = 0.0
            for step in 0..<30 {
                now += Double.random(in: 0.1...20, using: &generator)
                switch Int.random(in: 0..<4, using: &generator) {
                case 0 where route.currentMeeting == nil:
                    route.begin(meeting: "m\(step)", at: now); intervals.append(("m\(step)", now, nil))
                case 1 where route.currentMeeting != nil:
                    route.endMeeting(at: now); intervals[intervals.count - 1].to = now
                default:
                    let at = now - Double.random(in: 0...30, using: &generator)      // a slow read reports late
                    let during = intervals.first { at >= $0.from && ($0.to.map { at < $0 } ?? true) }
                    switch route.home(at: at) {
                    case .meeting(let id): XCTAssertEqual(during?.id, id)
                    case .day: XCTAssertNil(during, "a reading taken during \(during?.id ?? "") reached the day")
                    case .nowhere: break
                    }
                }
            }
        }
    }

    // MARK: The journal

    func testADayIsWrittenAsItGoesAndReadsBackWhole() throws {
        let store = ScreenDayStore(root: root)
        var journal = ScreenDayJournal(store: store, now: date(11, 9), calendar: calendar)
        journal.note(app: "Xcode", bundleID: "com.apple.dt.Xcode", category: "Developer tools", window: "AppModel.swift", meetingID: nil, at: date(11, 9, 0, 0))
        journal.keep(observation("func start() async throws the recording begins here", vector: [0.25, -0.5, 1]), at: date(11, 9, 0, 1))
        journal.note(app: "Xcode", bundleID: "com.apple.dt.Xcode", category: "Developer tools", window: "AppModel.swift", meetingID: nil, at: date(11, 9, 0, 3))
        XCTAssertTrue(try journal.flush(now: date(11, 9, 0, 3)).wrote, "what has just appeared is written at once")
        journal.endMoment(at: date(11, 9, 0, 30)); journal.endUsage()
        let flushed = try journal.flush(now: date(11, 9, 0, 30))
        XCTAssertEqual(flushed.ended, 1)

        let day = try XCTUnwrap(store.load("2026-11-11"))
        XCTAssertEqual(day.start, date(11, 0))
        XCTAssertEqual(day.moments.count, 1)
        XCTAssertEqual(day.moments[0].start, 9 * 3600 + 1, accuracy: 0.01)
        XCTAssertEqual(day.moments[0].end, 9 * 3600 + 30, accuracy: 0.01)
        XCTAssertEqual(day.moments[0].embedding, [0.25, -0.5, 1], "the picture vector survives the log exactly")
        XCTAssertEqual(day.moments[0].embeddingModelID, "model-a")
        XCTAssertEqual(day.usage.map(\.app), ["Xcode"])
        XCTAssertEqual(day.byApp().first?.moments, 1)
        XCTAssertEqual(day, journal.current)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url("2026-11-11").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testAnOpenWindowIsNotRewrittenEverySecond() throws {
        let store = ScreenDayStore(root: root)
        var journal = ScreenDayJournal(store: store, now: date(11, 9), calendar: calendar)
        var writes = 0
        for second in 0..<120 {
            let now = date(11, 9, second / 60, second % 60)
            journal.note(app: "Pages", bundleID: "com.apple.iWork.Pages", category: nil, window: "Plan", meetingID: nil, at: now)
            journal.keep(observation("the quarterly plan grows by one more word " + String(repeating: "word ", count: second), app: "Pages", bundle: "com.apple.iWork.Pages", window: "Plan"), at: now)
            if try journal.flush(now: now).wrote { writes += 1 }
        }
        XCTAssertLessThanOrEqual(writes, 6, "two minutes in one growing window: written when it appears, then every half minute")
        XCTAssertGreaterThanOrEqual(writes, 3)
        _ = try journal.flush(now: date(11, 9, 2, 0), force: true)
        XCTAssertEqual(store.load("2026-11-11")?.moments.count, 1)
        XCTAssertTrue(store.load("2026-11-11")?.moments[0].text.hasSuffix(String(repeating: "word ", count: 119).trimmingCharacters(in: .whitespaces)) ?? false)
    }

    func testMidnightEndsTheDayAndStartsTheNext() throws {
        let store = ScreenDayStore(root: root)
        var journal = ScreenDayJournal(store: store, now: date(11, 23, 59, 0), calendar: calendar)
        // The watcher notes the app in front once a second, straight through midnight.
        for second in 0..<82 {
            let now = date(11, 23, 59, 0).addingTimeInterval(Double(second))
            journal.note(app: "Notes", bundleID: "com.apple.Notes", category: "Notes", window: "Ideas", meetingID: nil, at: now)
            if second == 30 { journal.keep(observation("late night ideas about the launch plan", app: "Notes", bundle: "com.apple.Notes", window: "Ideas"), at: now) }
            if second == 80 { journal.keep(observation("late night ideas about the launch plan and more", app: "Notes", bundle: "com.apple.Notes", window: "Ideas"), at: now) }
        }
        _ = try journal.flush(now: date(12, 0, 0, 21), force: true)
        XCTAssertEqual(journal.day, "2026-11-12")
        XCTAssertEqual(store.days(), ["2026-11-12", "2026-11-11"])
        let first = try XCTUnwrap(store.load("2026-11-11")), second = try XCTUnwrap(store.load("2026-11-12"))
        XCTAssertEqual(first.moments.count, 1); XCTAssertEqual(second.moments.count, 1)
        XCTAssertLessThanOrEqual(first.moments[0].end, 86_400, "the first day's moment ends by midnight")
        XCTAssertEqual(second.moments[0].start, 20, accuracy: 0.01)
        XCTAssertEqual(first.usage.count, 1); XCTAssertEqual(second.usage.count, 1)
        XCTAssertEqual(first.usage[0].end, 86_399, accuracy: 0.01, "the app's span ends with the day")
        XCTAssertEqual(second.usage[0].start, 0, accuracy: 0.01, "and starts again with the next")
    }

    func testARelaunchCarriesOnWithTheSameDay() throws {
        let store = ScreenDayStore(root: root)
        var morning = ScreenDayJournal(store: store, now: date(11, 9), calendar: calendar)
        morning.keep(observation("morning standup notes and the list of blockers"), at: date(11, 9, 0, 5))
        morning.endMoment(at: date(11, 9, 5)); _ = try morning.flush(now: date(11, 9, 5), force: true)
        var afternoon = ScreenDayJournal(store: store, now: date(11, 14), calendar: calendar)
        afternoon.keep(observation("afternoon design review of the capture pipeline", window: "Review"), at: date(11, 14, 0, 5))
        afternoon.endMoment(at: date(11, 14, 5)); _ = try afternoon.flush(now: date(11, 14, 5), force: true)
        XCTAssertEqual(store.load("2026-11-11")?.moments.map { $0.text.prefix(9) }, ["morning s", "afternoon"])
        XCTAssertEqual(afternoon.momentCount, 2)
    }

    func testClearingTodayLeavesNothingToComeBack() throws {
        let store = ScreenDayStore(root: root)
        var journal = ScreenDayJournal(store: store, now: date(11, 9), calendar: calendar)
        journal.keep(observation("something the person wants gone from the record"), at: date(11, 9, 0, 5))
        _ = try journal.flush(now: date(11, 9, 0, 6), force: true)
        try journal.clear()
        XCTAssertNil(store.load("2026-11-11"))
        // The window is still in front: later flushes must not write the forgotten text back.
        _ = try journal.flush(now: date(11, 9, 1, 0), force: true)
        XCTAssertNil(store.load("2026-11-11"), "a cleared day does not come back from memory")
        journal.keep(observation("a new window opened after the clearing"), at: date(11, 9, 2, 0))
        _ = try journal.flush(now: date(11, 9, 2, 1), force: true)
        XCTAssertEqual(store.load("2026-11-11")?.moments.map(\.text), ["a new window opened after the clearing"])
    }

    func testALineCutShortByACrashCostsOnlyThatLine() throws {
        let store = ScreenDayStore(root: root)
        var journal = ScreenDayJournal(store: store, now: date(11, 9), calendar: calendar)
        journal.keep(observation("the first window with enough words to keep"), at: date(11, 9, 0, 5))
        journal.endMoment(at: date(11, 9, 1)); _ = try journal.flush(now: date(11, 9, 1), force: true)
        let handle = try FileHandle(forWritingTo: store.url("2026-11-11"))
        try handle.seekToEnd(); try handle.write(contentsOf: Data(#"{"t":"m","moment":{"id":"x","start":1,"#.utf8)); try handle.close()
        XCTAssertEqual(store.load("2026-11-11")?.moments.count, 1)
    }

    func testOldDaysArePrunedAndTodayNeverIs() throws {
        let store = ScreenDayStore(root: root)
        for day in 1...11 { try store.save(ScreenDay(day: String(format: "2026-11-%02d", day), start: date(day, 0))) }
        let gone = try store.prune(keeping: 7, now: date(11, 12), calendar: calendar)
        XCTAssertEqual(gone.sorted(), ["2026-11-01", "2026-11-02", "2026-11-03", "2026-11-04"])
        XCTAssertEqual(store.days().count, 7)
        XCTAssertEqual(try store.prune(keeping: 1, now: date(11, 12), calendar: calendar).count, 6)
        XCTAssertEqual(store.days(), ["2026-11-11"])
        XCTAssertEqual(try store.prune(keeping: 0, now: date(30, 12), calendar: calendar), [], "zero keeps everything")
    }

    func testADayCanBeAskedAboutOneApp() {
        var day = ScreenDay(day: "2026-11-11", start: date(11, 0))
        day.moments = [ScreenMoment(start: 10, end: 20, text: "a", app: "Safari", bundleID: "com.apple.Safari"),
                       ScreenMoment(start: 30, end: 40, text: "b", app: "Xcode", bundleID: "com.apple.dt.Xcode")]
        day.usage = [AppSpan(bundleID: "com.apple.Safari", app: "Safari", category: "Browser", start: 10, end: 25),
                     AppSpan(bundleID: "com.apple.dt.Xcode", app: "Xcode", start: 30, end: 100),
                     AppSpan(bundleID: "com.apple.Safari", app: "Safari", category: "Browser", start: 100, end: 110)]
        XCTAssertEqual(day.moments(app: "safari").map(\.text), ["a"])
        XCTAssertEqual(day.moments(app: "com.apple.dt.Xcode").map(\.text), ["b"])
        let totals = day.byApp()
        XCTAssertEqual(totals.map(\.app), ["Xcode", "Safari"])
        XCTAssertEqual(totals[1].seconds, 25, accuracy: 0.01); XCTAssertEqual(totals[1].spans, 2); XCTAssertEqual(totals[1].moments, 1)
    }

    func testOneAppCanBeForgottenFromADayWhileItIsBeingWritten() throws {
        let store = ScreenDayStore(root: root)
        var journal = ScreenDayJournal(store: store, now: date(11, 9), calendar: calendar)
        for second in 0..<6 {
            let now = date(11, 9, 0, second)
            journal.note(app: "Bank", bundleID: "com.example.bank", category: "Finance", window: "Accounts", meetingID: nil, at: now)
            if second == 1 { journal.keep(observation("account balance and recent transactions listed here", app: "Bank", bundle: "com.example.bank", window: "Accounts"), at: now) }
        }
        for second in 6..<12 {
            let now = date(11, 9, 0, second)
            journal.note(app: "Xcode", bundleID: "com.apple.dt.Xcode", category: "Developer tools", window: "A.swift", meetingID: nil, at: now)
            if second == 7 { journal.keep(observation("the code that stays in the journal afterwards"), at: now) }
        }
        try journal.forget(bundleID: "com.example.bank", now: date(11, 9, 0, 12))
        _ = try journal.flush(now: date(11, 9, 1, 0), force: true)
        let day = try XCTUnwrap(store.load("2026-11-11"))
        XCTAssertEqual(day.moments.map(\.app), ["Xcode"])
        XCTAssertEqual(day.usage.map(\.app), ["Xcode"], "not its text, and not that it was in front")
        XCTAssertFalse(try String(contentsOf: store.url("2026-11-11"), encoding: .utf8).contains("balance"), "nothing of it is left in the log")
    }

    // MARK: The local API and links

    func testTheScreenRoutes() {
        XCTAssertEqual(try? APIRoute.match(method: "GET", path: "/v1/screen/days").get(), .screenDays)
        XCTAssertEqual(try? APIRoute.match(method: "GET", path: "/v1/screen/days/2026-11-11").get(), .screenDay("2026-11-11"))
        XCTAssertEqual(try? APIRoute.match(method: "GET", path: "/v1/screen/days/today").get(), .screenDay("today"))
        XCTAssertEqual(try? APIRoute.match(method: "POST", path: "/v1/screen/days/2026-11-11/delete").get(), .deleteScreenDay("2026-11-11"))
        XCTAssertEqual(try? APIRoute.match(method: "POST", path: "/v1/screen/pause").get(), .pauseScreen)
        XCTAssertEqual(APIRoute.match(method: "GET", path: "/v1/screen/days/../../etc"), .failure(.notFound))
        XCTAssertEqual(APIRoute.match(method: "GET", path: "/v1/screen/days/2026-1-1"), .failure(.notFound), "only a whole date names a day")
        XCTAssertEqual(APIRoute.match(method: "GET", path: "/v1/screen/pause"), .failure(.methodNotAllowed))
    }

    func testADayIsShapedForTheAPIByAppAndTime() {
        var day = ScreenDay(day: "2026-11-11", start: date(11, 0))
        day.moments = [ScreenMoment(start: 100, end: 200, text: "one", app: "Safari", bundleID: "com.apple.Safari", window: "Docs"),
                       ScreenMoment(start: 300, end: 400, text: "two", app: "Xcode", bundleID: "com.apple.dt.Xcode", window: "A.swift"),
                       ScreenMoment(start: 500, end: 600, text: "three", app: "Safari", bundleID: "com.apple.Safari", window: "News")]
        day.usage = [AppSpan(bundleID: "com.apple.Safari", app: "Safari", category: "Browser", start: 100, end: 250, windows: ["Docs"]),
                     AppSpan(bundleID: "com.apple.dt.Xcode", app: "Xcode", start: 300, end: 450, windows: ["A.swift"], meetingID: "m1")]
        let all = APIShapes.screenDay(day)
        XCTAssertEqual(all.moments.map(\.text), ["one", "two", "three"]); XCTAssertFalse(all.truncated)
        XCTAssertEqual(all.moments[0].startedAt, date(11, 0, 1, 40))
        XCTAssertEqual(all.moments[0].link, "workscribe://screen/2026-11-11?t=100.0")
        XCTAssertEqual(all.usage.last?.meetingId, "m1")
        let safari = APIShapes.screenDay(day, app: "safari", from: 450, limit: 5)
        XCTAssertEqual(safari.moments.map(\.text), ["three"])
        XCTAssertEqual(safari.apps.count, 2, "the day's apps are listed whichever one was asked about")
        XCTAssertTrue(APIShapes.screenDay(day, limit: 2).truncated)
        XCTAssertEqual(APIShapes.screenSummary(day).seconds, 300)
    }

    func testAnAskMomentFromTheDayOpensTheDayAndSaysWhen() {
        var moment = AskMoment(id: "chunk:1", sourceKind: "screen", ref: "screen-day:2026-11-11", title: "Screen · Wed 11 Nov 2026",
                               kind: "screen", start: 34_200, end: 34_260, text: "Quarterly forecast")
        moment.window = "Numbers — Forecast"
        XCTAssertEqual(moment.link, .screen(day: "2026-11-11", seconds: 34_200))
        XCTAssertEqual(moment.locator, "09:30 · Numbers — Forecast")
        XCTAssertFalse(moment.isMeeting)
        XCTAssertEqual(APIShapes.momentKind(moment), "screen")
        let fromMeeting = AskMoment(id: "chunk:2", sourceKind: "meeting", ref: UUID().uuidString, title: "Standup", kind: "screen", start: 61, text: "slide")
        XCTAssertNil(fromMeeting.screenDay); XCTAssertEqual(fromMeeting.locator, "01:01")
    }

    // MARK: Search

    func testADayIsFoundBySearchAndLeavesTheIndexWithItsJournal() async throws {
        let store = ScreenDayStore(root: root)
        var day = ScreenDay(day: "2026-11-11", start: date(11, 0))
        day.moments = [ScreenMoment(start: 34_200, end: 34_260, text: "Quarterly revenue forecast spreadsheet with the pipeline totals",
                                    app: "Numbers", bundleID: "com.apple.iWork.Numbers", window: "Forecast")]
        try store.save(day)
        let index = try SearchIndex(url: root.appendingPathComponent("index.sqlite"))
        let indexer = ScreenDayIndexer(index: index, embedder: nil)
        var report = try await indexer.sync(store: store)
        XCTAssertEqual(report.indexed, 1)
        let hit = try XCTUnwrap(try index.search(SearchRequest("revenue forecast")).hits.first)
        XCTAssertEqual(hit.sourceKind, .screen)
        XCTAssertEqual(hit.kind, .screen)
        XCTAssertEqual(hit.window, "Numbers — Forecast")
        XCTAssertEqual(hit.link, .screen(day: "2026-11-11", seconds: 34_200))
        XCTAssertEqual(WorkScribeLink(url: hit.link.url), hit.link, "the link survives being written and read")
        XCTAssertTrue(hit.title?.hasPrefix("Screen · ") ?? false)

        report = try await indexer.sync(store: store)
        XCTAssertEqual(report.unchanged, 1, "an unchanged day is not indexed again")

        // The meeting indexer keeps the index in step with meetings; a day of screen reading is not its to remove.
        _ = try await MeetingIndexer(index: index, embedder: nil).sync(store: MeetingStore(root: root.appendingPathComponent("Meetings")))
        XCTAssertFalse(try index.search(SearchRequest("revenue forecast")).hits.isEmpty)

        try store.delete("2026-11-11")
        report = try await indexer.sync(store: store)
        XCTAssertEqual(report.removed, 1)
        XCTAssertTrue(try index.search(SearchRequest("revenue forecast")).hits.isEmpty, "a deleted day is not searchable")
    }
}
