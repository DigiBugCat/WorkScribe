import AppKit
import Foundation
import WorkScribeCore

/// `WorkScribe --verify-screen <seconds>`: reads a rendered test slide (no permission needed), then records the screen
/// for `seconds` into a throwaway meeting, prints its moments as JSON, and deletes everything it wrote.
enum ScreenVerification {
    @MainActor
    static func run(seconds: Double) async throws {
        var report: [String: Any] = [:]
        let slide = renderSlide()
        let started = Date()
        let read = await ScreenOCR.read(slide)
        report["synthetic_ocr"] = ["text": read.text, "lines": read.lines.count, "seconds": Date().timeIntervalSince(started)]
        report["screen_permission"] = CGPreflightScreenCaptureAccess()
        guard CGPreflightScreenCaptureAccess() else {
            report["capture"] = ["skipped": "Screen Recording permission unavailable; synthetic OCR only"]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]))
            FileHandle.standardOutput.write(Data([10]))
            return
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workscribe-screen-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let meeting = Meeting(title: "Screen verification")
        try store.save(meeting)
        var settings = ScreenCaptureSettings()
        if CommandLine.arguments.contains("--window") { settings.target = .window }
        let recorder = ScreenRecorder(folder: try store.directory(meeting.id), meetingID: meeting.id, meetingStart: meeting.startedAt,
                                      store: store, settings: settings)
        var states: [String] = []
        recorder.onState = { states.append($0.label) }
        do {
            let info = try await recorder.start()
            report["target"] = info.target
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            let live = ScreenContext.current()
            let result = await recorder.stop()
            let folder = try store.directory(meeting.id)
            let video = folder.appendingPathComponent(ScreenFiles.video)
            let thumbnails = (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(ScreenFiles.thumbnails).path)) ?? []
            report["capture"] = [
                "state": result.info.state, "failure": result.info.failure as Any? ?? NSNull(),
                "video_offset_seconds": result.info.offset as Any? ?? NSNull(),
                "video_bytes": (try? FileManager.default.attributesOfItem(atPath: video.path)[.size] as? Int) ?? 0,
                "thumbnails": thumbnails.count,
                "live_context_app": live?.app as Any? ?? NSNull(),
                "moments": result.moments.map { ["start": $0.start, "end": $0.end, "frames": $0.frames, "app": $0.app ?? "",
                                                 "window": $0.window ?? "", "text": String($0.text.prefix(300))] },
            ]
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
