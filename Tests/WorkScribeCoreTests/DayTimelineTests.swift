import XCTest
@testable import WorkScribeCore

/// The day view's rows and strip, from the app spans the journal keeps and the day's meetings.
final class DayTimelineTests: XCTestCase {
    private func span(_ app: String, _ start: Double, _ end: Double, _ windows: [String] = [], meeting: String? = nil) -> AppSpan {
        AppSpan(id: "\(app)-\(Int(start))", bundleID: "com.example." + app.lowercased(), app: app, start: start, end: end, windows: windows, meetingID: meeting)
    }

    func testAQuickLookElsewhereDoesNotSplitTheAppAroundItOrGetARow() {
        let timeline = DayTimeline.build(spans: [
            span("Xcode", 36_000, 36_600, ["AppModel.swift"]),
            span("Chrome", 36_600, 36_615, ["Docs"]),
            span("Xcode", 36_620, 37_200, ["Meeting.swift", "AppModel.swift"]),
        ], meetings: [], now: 50_000)
        XCTAssertEqual(timeline.rows.map(\.title), ["Xcode"])
        XCTAssertEqual(timeline.rows[0].start, 36_000); XCTAssertEqual(timeline.rows[0].end, 37_200)
        XCTAssertEqual(timeline.rows[0].seconds, 1_180, "time in front, not the clock time between first and last")
        XCTAssertEqual(timeline.rows[0].windows, ["AppModel.swift", "Meeting.swift"])
        XCTAssertEqual(timeline.totals.map(\.app), ["Xcode", "Chrome"], "the quick look still counts towards the day")
        XCTAssertEqual(timeline.totals[1].seconds, 15)
        XCTAssertEqual(timeline.segments.count, 3, "and is on the strip")
    }

    func testRowsAreNewestFirstAndALongStretchElsewhereStartsANewRow() {
        let timeline = DayTimeline.build(spans: [
            span("Xcode", 36_000, 36_600), span("Chrome", 36_600, 37_000), span("Xcode", 37_000, 37_400),
        ], meetings: [], now: 50_000)
        XCTAssertEqual(timeline.rows.map(\.title), ["Xcode", "Chrome", "Xcode"])
        XCTAssertEqual(timeline.rows.map(\.start), [37_000, 36_600, 36_000])
        XCTAssertFalse(timeline.rows.contains(where: \.current), "nothing here is still going")
    }

    func testTheSameAppMuchLaterIsAnotherRow() {
        let timeline = DayTimeline.build(spans: [span("Xcode", 36_000, 36_600), span("Xcode", 40_000, 40_600)], meetings: [], now: 50_000)
        XCTAssertEqual(timeline.rows.count, 2)
    }

    func testAMeetingIsItsOwnRowWithWhatWasOnScreenAndSplitsTheAppAroundIt() {
        let timeline = DayTimeline.build(spans: [
            span("Xcode", 36_000, 36_600, ["Before.swift"]),
            span("Keynote", 36_600, 36_840, ["Roadmap.key"], meeting: "M1"),
            span("Zoom", 36_840, 36_900, ["Zoom Meeting"], meeting: "M1"),
            span("Xcode", 36_900, 37_500, ["After.swift"]),
        ], meetings: [.init(id: "M1", title: "Planning", start: 36_600, end: 36_900)], now: 50_000)
        XCTAssertEqual(timeline.rows.map(\.title), ["Xcode", "Planning", "Xcode"])
        let meeting = timeline.rows[1]
        XCTAssertTrue(meeting.isMeeting)
        XCTAssertEqual(meeting.seconds, 300)
        XCTAssertEqual(meeting.windows, ["Roadmap.key", "Zoom Meeting"])
        XCTAssertFalse(timeline.rows.contains { $0.title == "Keynote" || $0.title == "Zoom" }, "what was in front during the meeting is the meeting's")
        XCTAssertEqual(timeline.meetings.map(\.start), [36_600])
        XCTAssertEqual(timeline.totals.first { $0.app == "Keynote" }?.seconds, 240, "it still counts towards the day by application")
    }

    func testAMeetingStillBeingRecordedRunsToNow() {
        let timeline = DayTimeline.build(spans: [], meetings: [.init(id: "M1", title: "Standup", start: 36_000, end: nil)], now: 36_300)
        XCTAssertEqual(timeline.rows.map(\.current), [true])
        XCTAssertEqual(timeline.rows[0].seconds, 300)
    }

    func testTheLatestStretchIsCurrentHoweverShortAndAnOldShortOneIsNot() {
        let now = 40_000.0
        let going = DayTimeline.build(spans: [span("Xcode", 36_000, 36_600), span("Slack", now - 8, now - 2)], meetings: [], now: now)
        XCTAssertEqual(going.rows.map(\.title), ["Slack", "Xcode"])
        XCTAssertEqual(going.rows.map(\.current), [true, false])
        let gone = DayTimeline.build(spans: [span("Xcode", 36_000, 36_600), span("Slack", 37_000, 37_006)], meetings: [], now: now)
        XCTAssertEqual(gone.rows.map(\.title), ["Xcode"], "six seconds an hour ago is not a row")
    }

    func testTheStripRunsFromTheHourTheDayBeganInToNow() {
        let timeline = DayTimeline.build(spans: [span("Xcode", 9.5 * 3600, 10 * 3600)], meetings: [], now: 14.25 * 3600)
        XCTAssertEqual(timeline.from, 9 * 3600); XCTAssertEqual(timeline.to, 14.25 * 3600)
        let empty = DayTimeline.build(spans: [], meetings: [], now: 8 * 3600)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertLessThan(empty.from, empty.to)
    }

    func testEveryStretchOnTheStripLiesInsideItAndRowsNeverOverlapForOneApp() {
        // Any order of app switches, some brief, some in meetings.
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            var time = 30_000.0
            var spans: [AppSpan] = []
            for index in 0..<Int.random(in: 1...40, using: &generator) {
                let length = Double([4, 12, 45, 200, 900].randomElement(using: &generator)!)
                let app = ["Xcode", "Chrome", "Slack"].randomElement(using: &generator)!
                spans.append(AppSpan(id: "s\(index)", bundleID: "com.example." + app, app: app, start: time, end: time + length,
                                     meetingID: Int.random(in: 0..<8, using: &generator) == 0 ? "M" : nil))
                time += length + Double([0, 1, 30, 400].randomElement(using: &generator)!)
            }
            let timeline = DayTimeline.build(spans: spans.shuffled(using: &generator), meetings: [.init(id: "M", title: "M", start: 30_000, end: 30_100)], now: time + 500)
            for segment in timeline.segments { XCTAssertGreaterThanOrEqual(segment.start, timeline.from); XCTAssertLessThanOrEqual(segment.end, timeline.to) }
            XCTAssertEqual(timeline.seconds, spans.reduce(0) { $0 + $1.seconds }, accuracy: 0.001, "no time is lost or counted twice")
            let apps = timeline.rows.filter { !$0.isMeeting }
            XCTAssertEqual(apps.map(\.start), apps.map(\.start).sorted(by: >), "newest first")
            for (later, earlier) in zip(apps, apps.dropFirst()) { XCTAssertGreaterThanOrEqual(later.start, earlier.end - 0.001, "rows do not overlap") }
            XCTAssertLessThanOrEqual(apps.reduce(0) { $0 + $1.seconds }, spans.filter { $0.meetingID == nil }.reduce(0) { $0 + $1.seconds } + 0.001)
        }
    }

    func testLengthsAreSaidInTheFewestWords() {
        XCTAssertEqual(DayTimeline.length(45), "45 sec")
        XCTAssertEqual(DayTimeline.length(24 * 60), "24 min")
        XCTAssertEqual(DayTimeline.length(3600), "1h")
        XCTAssertEqual(DayTimeline.length(4_680), "1h 18m")
        XCTAssertEqual(DayTimeline.length(7_500), "2h 05m")
    }

    // MARK: Asking of one kind of source

    func testAskScopeKeepsOnlyItsKindOfSource() {
        let said = AskMoment(id: "1", sourceKind: "meeting", ref: "M", title: "Planning", kind: ChunkKind.meetingSegment.rawValue, text: "said")
        let shown = AskMoment(id: "2", sourceKind: "meeting", ref: "M", title: "Planning", kind: "screen", text: "shown in the meeting")
        let read = AskMoment(id: "3", sourceKind: "screen", ref: ScreenDaySource.ref("2026-11-12"), title: "Chrome", kind: "screen", text: "read outside meetings")
        let note = AskMoment(id: "4", sourceKind: "vault", ref: "/vault/a.md", title: "a", kind: "document", text: "a note")
        let file = AskMoment(id: "5", sourceKind: "file", ref: "/files/a.pdf", title: "a", kind: "document", text: "a file")
        let all = [said, shown, read, note, file]
        XCTAssertEqual(all.filter(AskScope.everything.includes).map(\.id), ["1", "2", "3", "4", "5"])
        XCTAssertEqual(all.filter(AskScope.meetings.includes).map(\.id), ["1", "2"])
        XCTAssertEqual(all.filter(AskScope.screen.includes).map(\.id), ["2", "3"], "what was on screen, in a meeting or outside one")
        XCTAssertEqual(all.filter(AskScope.notes.includes).map(\.id), ["4", "5"])
    }

    func testAConversationSavedBeforeScopesStillLoads() throws {
        let old = #"{"id":"c","title":"t","createdAt":0,"updatedAt":0,"pinned":false,"origin":"quick","messages":[],"attachments":[]}"#
        let conversation = try JSONDecoder().decode(Conversation.self, from: Data(old.utf8))
        XCTAssertNil(conversation.scope)
    }

    // MARK: The Mac's own dialogs

    func testAPermissionAlertOrPasswordPromptIsNotAnApplication() {
        XCTAssertTrue(ScreenPrivacy.isSystemUI("com.apple.UserNotificationCenter"))
        XCTAssertTrue(ScreenPrivacy.isSystemUI("com.apple.securityagent"), "whatever the case")
        XCTAssertFalse(ScreenPrivacy.isSystemUI("com.apple.Safari"))
        XCTAssertFalse(ScreenPrivacy.isSystemUI("com.apple.finder"), "Finder is an app the person works in")
        XCTAssertFalse(ScreenPrivacy.isSystemUI(nil))
    }
}
