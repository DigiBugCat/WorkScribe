import AppKit
import SwiftUI
import WorkScribeCore

/// `WorkScribe --render-ui <folder>`: draws the popover in each of its states from made-up data, off screen, and
/// writes one PNG per state. Nothing is read from the real library, the screen is not read, Codex is not called,
/// and no permission is needed. For looking at a change to the popover without running the app.
enum UIVerification {
    @MainActor
    static func run(folder: URL) async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workscribe-ui-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = AppModel(store: MeetingStore(root: root.appendingPathComponent("Meetings")))
        let ask = AskService(model: model, store: ConversationStore(root: root.appendingPathComponent("Conversations")), generator: SampleAnswer())
        let now = Date(), start = Calendar.current.startOfDay(for: now)
        let seconds = now.timeIntervalSince(start)
        func meeting(_ title: String, began: Double, ended: Double) -> Meeting {
            var meeting = Meeting(title: title)
            meeting.startedAt = now.addingTimeInterval(-began * 60); meeting.endedAt = now.addingTimeInterval(-ended * 60)
            meeting.status = "complete"
            meeting.segments = [Segment(source: "system", speaker: "Speaker 1", start: 0, end: 4, text: "Let’s start."),
                                Segment(source: "microphone", speaker: "You", start: 4, end: 8, text: "Sure.")]
            return meeting
        }
        let beta = meeting("Checkout redesign review", began: 30, ended: 24)
        let migration = meeting("Search ranking experiments", began: 190, ended: 157)
        let earlier = [("Supplier onboarding", 1_500.0, 1_497.0), ("Billing export questions", 1_520, 1_516),
                       ("Quarterly planning", 1_560, 1_555)].map { meeting($0.0, began: $0.1, ended: $0.2) }
        model.library = [beta, migration] + earlier
        func span(_ app: String, _ id: String, _ category: String, _ from: Double, _ to: Double, _ windows: [String], meeting: String? = nil) -> AppSpan {
            AppSpan(bundleID: id, app: app, category: category, start: max(0, seconds - from * 60), end: max(0, seconds - to * 60),
                    windows: windows, meetingID: meeting)
        }
        let xcode = "com.apple.dt.Xcode", chrome = "com.google.Chrome", slack = "com.tinyspeck.slackmacgap"
        model.screenUsage = DayUsage(start: start, spans: [
            span("Xcode", xcode, "Developer tools", 330, 291, ["AppModel.swift"]),
            span("Slack", slack, "Chat", 290, 271, ["#eng"]),
            span("Xcode", xcode, "Developer tools", 270, 192, ["MeetingRetention.swift", "RetentionRaceTests.swift", "Meeting.swift", "Package.swift", "README.md", "Notes.swift", "Line.swift"]),
            span("Keynote", "com.apple.iWork.Keynote", "Productivity", 190, 157, ["Ranking experiment plan"], meeting: migration.id),
            span("Google Chrome", chrome, "Browser", 120, 86, ["Experiment results", "GitHub"]),
            span("Finder", "com.apple.finder", "Utilities", 85.3, 85, ["Downloads"]),
            span("Slack", slack, "Chat", 84, 72, ["#checkout"]),
            span("Google Chrome", chrome, "Browser", 70, 32, ["Swift concurrency docs", "GitHub", "Linear", "Figma", "Mail"]),
            span("Keynote", "com.apple.iWork.Keynote", "Productivity", 30, 24, ["Checkout flow.key"], meeting: beta.id),
            span("Xcode", xcode, "Developer tools", 24, 0, ["AppModel+Screen.swift"]),
        ])
        model.speechReady = true
        model.screenAccess = true
        model.screenMode = .allDay
        model.screenState = .recording
        model.screenApp = ScreenAppRef(name: "Xcode", bundleID: xcode)
        func popover(showing: (question: String, conversation: String)? = nil) -> RecorderView {
            RecorderView(model: model, openWindow: {}, ask: ask, showing: showing)
        }

        UserDefaults.standard.set("day", forKey: "popoverLens")
        try await snapshot(popover(), "1-day", folder)
        try await snapshot(popover(), "1-day-light", folder, dark: false)
        UserDefaults.standard.set("meetings", forKey: "popoverLens")
        try await snapshot(popover(), "2-meetings", folder)
        UserDefaults.standard.set("day", forKey: "popoverLens")

        ask.register(SampleMoments(meeting: beta.id, day: ScreenDayStore.day(now).id, at: seconds))
        let question = "what did we decide about the launch date?"
        let asked = ask.ask(question, in: nil, origin: "popover")
        for _ in 0..<50 where ask.working.contains(asked.conversation) { try await Task.sleep(nanoseconds: 100_000_000) }
        try await snapshot(popover(showing: (question, asked.conversation)), "3-ask", folder)

        model.screenCapturePaused = true; model.screenState = .paused
        try await snapshot(popover(), "4-paused", folder)
        model.screenCapturePaused = false; model.screenState = .privateApp("1Password"); model.screenHiddenBundleID = "com.1password.1password"
        try await snapshot(popover(), "5-off-limits", folder)
        model.screenHiddenBundleID = nil; model.screenMode = .off; model.screenState = .off
        try await snapshot(popover(), "6-screen-off", folder)

        model.screenMode = .allDay; model.screenState = .recording
        model.screenApp = ScreenAppRef(name: "Keynote", bundleID: "com.apple.iWork.Keynote")
        var live = Meeting(title: "Checkout redesign review")
        live.startedAt = now.addingTimeInterval(-761); live.recordingTrigger = "call:Zoom"
        live.segments = [
            Segment(source: "system", speaker: "Speaker 1", start: 731, end: 740, text: "So if we launch on the ninth that still leaves a week to test."),
            Segment(source: "microphone", speaker: "You", start: 741, end: 748, text: "Fine, but only bug fixes after the second. Nothing else goes in."),
            Segment(source: "system", speaker: "Speaker 2", start: 749, end: 755, text: "Ten percent of visitors first, then we open it up."),
        ]
        model.meeting = live; model.phase = "recording"
        model.screenMoments = [
            ScreenMoment(id: "a", start: 300, end: 420, text: "Checkout QA checklist", lines: nil, app: "Linear", bundleID: "com.linear", window: "Checkout QA checklist", thumbnail: nil),
            ScreenMoment(id: "b", start: 430, end: 760, text: "New checkout flow", lines: nil, app: "Keynote", bundleID: "com.apple.iWork.Keynote", window: "Checkout flow.key", thumbnail: nil),
        ]
        try await snapshot(popover(), "7-recording", folder)
        model.phase = "ready"; model.meeting = nil
        FileHandle.standardOutput.write(Data("Wrote the popover's states to \(folder.path)\n".utf8))
    }

    /// Lays the view out in a window that is never on a screen, and writes what it drew.
    @MainActor
    private static func snapshot<V: View>(_ view: V, _ name: String, _ folder: URL, dark: Bool = true) async throws {
        let size = NSSize(width: 400, height: 620)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        try await Task.sleep(nanoseconds: 700_000_000)
        hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CaptureError.message("Could not draw \(name)") }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CaptureError.message("Could not encode \(name)") }
        try png.write(to: folder.appendingPathComponent(name + ".png"))
        window.orderOut(nil)
    }

    private struct SampleAnswer: AnswerGenerator {
        var displayName: String { "Codex · sample" }
        var provider: String { "codex" }
        var modelName: String { "sample" }
        var isAvailable: Bool { true }
        func stream(_ prompt: AskPrompt) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield("The launch moves to the ninth, and only bug fixes go in after the second [1]. The new checkout opens to ten percent of visitors first [2]; the old flow stays as the fallback until the error rate has been checked [3].")
                continuation.finish()
            }
        }
    }

    private struct SampleMoments: AskMomentProvider {
        let meeting: String
        let day: String
        let at: Double
        func moments(for question: String, context: AskContext) async -> [AskMoment] {
            var said = AskMoment(id: "sample:1", sourceKind: SourceKind.meeting.rawValue, ref: meeting, title: "Checkout redesign review",
                                 kind: ChunkKind.meetingSegment.rawValue, start: 251, end: 262, speakers: ["Sam"],
                                 text: "So we launch on the ninth, bug fixes only after the second.", snippet: "…so we launch on the ninth, bug fixes only after the second…")
            said.attached = true
            var shown = AskMoment(id: "sample:2", sourceKind: SourceKind.meeting.rawValue, ref: meeting, title: "Checkout redesign review",
                                  kind: "screen", start: 300, end: 420, text: "Rollout: ten percent of visitors, then everyone", snippet: "Rollout: ten percent of visitors, then everyone")
            shown.window = "Linear — Checkout QA checklist"
            var read = AskMoment(id: "sample:3", sourceKind: SourceKind.screen.rawValue, ref: ScreenDaySource.ref(day), title: "Google Chrome",
                                 kind: "screen", start: max(0, at - 100 * 60), end: max(0, at - 95 * 60),
                                 text: "old_checkout: kept as fallback until the error rate is checked", snippet: "old_checkout: kept as fallback until the error rate is checked")
            read.window = "Experiment results"
            return [said, shown, read]
        }
    }
}
