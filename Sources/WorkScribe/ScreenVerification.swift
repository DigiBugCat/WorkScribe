import AppKit
import Foundation
import WorkScribeCore

/// `WorkScribe --verify-screen <seconds>`: reads a rendered test slide (no permission needed), then watches the
/// screen for `seconds` the way the app does all day: the first third into the day's journal, the middle third
/// into a throwaway meeting, the last third into the day again. Prints what it kept as JSON (by application, and
/// where each reading went) and deletes everything it wrote. Switch between a few windows while it runs.
enum ScreenVerification {
    @MainActor
    static func run(seconds: Double) async throws {
        var report: [String: Any] = [:]
        let slide = renderSlide()
        let started = Date()
        let read = await ScreenOCR.read(slide)
        report["synthetic_ocr"] = ["text": read.text, "lines": read.lines.count, "seconds": Date().timeIntervalSince(started)]
        report["accessibility_permission"] = ScreenReader.accessibilityAllowed
        report["screen_recording_permission"] = ScreenReader.picturesAllowed
        guard ScreenReader.accessibilityAllowed || ScreenReader.picturesAllowed else {
            report["capture"] = ["skipped": "Neither Accessibility nor Screen Recording is allowed for this process; synthetic OCR only"]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]))
            FileHandle.standardOutput.write(Data([10]))
            return
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workscribe-screen-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let days = ScreenDayStore(meetings: store)
        let meeting = Meeting(title: "Screen verification")
        try store.save(meeting)
        let watcher = ScreenWatcher(dayStore: days)
        var states: [String] = []
        watcher.onState = { states.append($0.label) }
        func rows(_ moments: [ScreenMoment]) -> [[String: Any]] {
            moments.map { moment in
                var row: [String: Any] = ["start": (moment.start * 10).rounded() / 10, "end": (moment.end * 10).rounded() / 10]
                row["readings"] = moment.frames; row["app"] = moment.app ?? ""; row["window"] = moment.window ?? ""
                row["source"] = moment.source ?? ""; row["url"] = moment.url ?? ""; row["picture_vector"] = moment.embedding != nil
                row["words"] = ScreenMomentBuilder.words(moment.text).count; row["text"] = String(moment.text.prefix(200))
                return row
            }
        }
        do {
            try watcher.start()
            let third = UInt64(seconds / 3 * 1_000_000_000)
            try await Task.sleep(nanoseconds: third)
            let begun = await watcher.beginMeeting(id: meeting.id, timeline: MeetingScreenTimeline(store: store, meetingID: meeting.id, start: meeting.startedAt))
            report["target"] = begun.info.target
            try await Task.sleep(nanoseconds: third)
            let live = ScreenContext.current()
            let ended = await watcher.endMeeting(begun.token)
            try await Task.sleep(nanoseconds: third)
            await watcher.stop()
            // Text only: no picture, video or sound may be left behind.
            let media = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
                .filter { ["wav", "pcm", "mov", "mp4", "jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
            guard media.isEmpty else { throw CaptureError.message("Screen capture persisted media") }
            var capture: [String: Any] = ["recorded_media_files": media.map(\.path), "state": ended?.info.state ?? "", "moments": rows(ended?.moments ?? [])]
            capture["failure"] = ended?.info.failure ?? ""; capture["live_context_app"] = live?.app ?? ""
            report["meeting"] = capture
            let day = days.load(ScreenDayStore.day(Date()).id)
            let meetingStart = meeting.startedAt.timeIntervalSince(day?.start ?? Date())
            var journal: [String: Any] = ["moments": rows(day?.moments ?? [])]
            journal["by_application"] = (day?.byApp() ?? []).map { total -> [String: Any] in
                ["app": total.app, "bundle_id": total.bundleID ?? "", "category": total.category ?? "", "seconds": (total.seconds * 10).rounded() / 10,
                 "moments": total.moments, "windows": total.windows]
            }
            journal["spans_during_the_meeting"] = (day?.usage ?? []).filter { $0.meetingID == meeting.id }.count
            // Each reading has one home: nothing in the day's journal may have been read while the meeting was recording.
            let window = (ended?.moments ?? []).reduce((Double.infinity, -Double.infinity)) { (min($0.0, $1.start), max($0.1, $1.end)) }
            let overlapping = (day?.moments ?? []).filter { $0.end - meetingStart > window.0 + 1 && $0.start - meetingStart < window.1 - 1 }
            journal["moments_overlapping_the_meeting"] = overlapping.count
            report["day"] = journal
            guard overlapping.isEmpty else { throw CaptureError.message("The day's journal kept text read during the meeting") }
        } catch {
            report["capture"] = ["error": error.localizedDescription]
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        report["states"] = states
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]))
        FileHandle.standardOutput.write(Data([10]))
    }

    /// A 1600×900 slide with a title and bullets.
    static func renderSlide() -> CGImage {
        let size = NSSize(width: 1600, height: 900)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            let title: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 64), .foregroundColor: NSColor.black]
            let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 36), .foregroundColor: NSColor.darkGray]
            "Q3 Marketing Budget Review".draw(at: NSPoint(x: 100, y: 720), withAttributes: title)
            for (index, line) in ["Cut advertising spend by a third", "Hire a product designer in October",
                                  "Invoice INV-4821 due on signature"].enumerated() {
                "• \(line)".draw(at: NSPoint(x: 120, y: 560 - CGFloat(index) * 90), withAttributes: body)
            }
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }
}
