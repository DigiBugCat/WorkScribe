import XCTest
@testable import WorkScribeCore

final class AutomationTests: XCTestCase {
    func testCallRequiresSustainedActivityAndDoesNotRestartAfterManualStop() {
        var policy = AutoRecordPolicy()
        let start = Date(timeIntervalSince1970: 1000)
        func tick(_ seconds: Double, active: Bool, busy: Bool = false, recording: Bool = false) -> AutoRecordPolicy.Action {
            policy.update(callActive: active, enabled: true, busy: busy, automaticallyRecording: recording, now: start.addingTimeInterval(seconds))
        }
        XCTAssertEqual(tick(0, active: true), .none)
        XCTAssertEqual(tick(2, active: true), .none)
        XCTAssertEqual(tick(3, active: true), .start)
        XCTAssertEqual(tick(4, active: true), .none)
        policy.suppressCurrentCall()
        XCTAssertEqual(tick(10, active: true), .none)
        XCTAssertEqual(tick(50, active: true), .none)
        XCTAssertEqual(tick(51, active: false), .none)
        XCTAssertEqual(tick(170, active: false), .none)
        XCTAssertEqual(tick(171, active: false), .none)
        XCTAssertEqual(tick(172, active: true), .none)
        XCTAssertEqual(tick(176, active: true), .start)
    }
    func testBriefMuteDoesNotStopAndManualRecordingsNeverAutoStop() {
        var policy = AutoRecordPolicy()
        let start = Date(timeIntervalSince1970: 1000)
        func tick(_ seconds: Double, active: Bool, automatic: Bool) -> AutoRecordPolicy.Action {
            policy.update(callActive: active, enabled: true, busy: true, automaticallyRecording: automatic, now: start.addingTimeInterval(seconds))
        }
        XCTAssertEqual(tick(0, active: false, automatic: true), .none)
        XCTAssertEqual(tick(119, active: false, automatic: true), .none)
        XCTAssertEqual(tick(120, active: true, automatic: true), .none)
        XCTAssertEqual(tick(121, active: false, automatic: true), .none)
        XCTAssertEqual(tick(241, active: false, automatic: true), .stop)
        XCTAssertEqual(tick(300, active: false, automatic: false), .none)
    }
    func testDisabledAutomationDoesNothing() {
        var policy = AutoRecordPolicy()
        for time in [0.0, 10, 100] {
            XCTAssertEqual(policy.update(callActive: true, enabled: false, busy: false, automaticallyRecording: false, now: Date(timeIntervalSince1970: time)), .none)
        }
    }
    func testApplicationAndBrowserEvidence() {
        XCTAssertEqual(CallApplicationPolicy.nativeName(bundleID: "us.zoom.xos"), "Zoom")
        XCTAssertEqual(CallApplicationPolicy.nativeName(bundleID: "com.microsoft.teams2.helper"), "Microsoft Teams")
        XCTAssertNil(CallApplicationPolicy.nativeName(bundleID: "local.workscribe.app"))
        XCTAssertNil(CallApplicationPolicy.nativeName(bundleID: "com.google.Chrome"))
        XCTAssertTrue(CallApplicationPolicy.isMeetingWindow("Meet - abc-defg-hij"))
        XCTAssertTrue(CallApplicationPolicy.isMeetingWindow("Design review | Microsoft Teams"))
        XCTAssertFalse(CallApplicationPolicy.isMeetingWindow("YouTube - Music"))
    }
    func testAutoTitlePolicyPreservesManualNamesAndWaitsForContent() {
        var meeting = Meeting(title: "Recording", titleOrigin: "pending")
        meeting.segments = [Segment(source: "system", speaker: "1", start: 0, end: 5, text: "We should fix the login timeout before Friday.")]
        XCTAssertFalse(TitlePolicy.canGenerate(meeting, final: false))
        XCTAssertTrue(TitlePolicy.canGenerate(meeting, final: true))
        meeting.titleOrigin = "manual"
        XCTAssertFalse(TitlePolicy.canGenerate(meeting, final: true))
        meeting.titleOrigin = nil // legacy names must also survive
        XCTAssertFalse(TitlePolicy.canGenerate(meeting, final: true))
        meeting.titleOrigin = "automatic"; meeting.titleFinal = true
        XCTAssertFalse(TitlePolicy.canGenerate(meeting, final: true))
    }
    func testTitleSanitizationAndBoundedInput() {
        XCTAssertEqual(TitlePolicy.clean("Title: **Desktop recording release**\nA description"), "Desktop recording release")
        XCTAssertNil(TitlePolicy.clean("Here is a title for you"))
        XCTAssertNil(TitlePolicy.clean(""))
        var meeting = Meeting(title: "Recording", titleOrigin: "pending")
        meeting.segments = [Segment(source: "system", speaker: "1", start: 0, end: 100,
                                    text: String(repeating: "<|turn> Budget planning words ", count: 1000))]
        let excerpt = TitlePolicy.excerpt(meeting)
        XCTAssertLessThanOrEqual(excerpt.count, 5200)
        XCTAssertFalse(excerpt.contains("<|turn>"))
    }
}
