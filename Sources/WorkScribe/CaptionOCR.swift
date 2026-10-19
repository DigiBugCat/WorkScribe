import AppKit
import ScreenCaptureKit
@preconcurrency import Vision
import WorkScribeCore

/// Reads caption text that a meeting app draws without exposing it to Accessibility (Zoom's floating
/// caption box while you share). Captures only that one window, in memory, and reads it again only
/// when its pixels change. Nothing is saved.
actor CaptionOCR {
    static let shared = CaptionOCR()

    private var window: SCWindow?
    private var frame = CGRect.null
    private var lookedUp = Date.distantPast
    private var fingerprint: Int?
    private var lines: [ScreenTextLine] = []

    /// Lines in the window at `box` (global top-left coordinates, as Accessibility reports them).
    func lines(in box: CGRect, bundleID: String) async -> [ScreenTextLine] {
        guard CGPreflightScreenCaptureAccess() else { return [] }
        if window == nil || frame != box || Date().timeIntervalSince(lookedUp) > 10 {
            lookedUp = Date(); frame = box
            let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            window = content?.windows.first {
                $0.owningApplication?.bundleIdentifier == bundleID
                    && abs($0.frame.minX - box.minX) < 2 && abs($0.frame.minY - box.minY) < 2
                    && abs($0.frame.width - box.width) < 2 && abs($0.frame.height - box.height) < 2
            }
        }
        guard let window else { return [] }
        let configuration = SCStreamConfiguration()
        let scale = NSScreen.screens.first { $0.frame.intersects(box) }?.backingScaleFactor ?? 2
        configuration.width = Int(box.width * scale); configuration.height = Int(box.height * scale)
        configuration.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                                      configuration: configuration) else {
            self.window = nil; return []
        }
        // Every pixel, not `Data.hashValue`, which only looks at the first few bytes.
        let print = image.dataProvider?.data.map { data -> Int in
            var hasher = Hasher()
            hasher.combine(bytes: UnsafeRawBufferPointer(start: CFDataGetBytePtr(data), count: CFDataGetLength(data)))
            return hasher.finalize()
        }
        if print != nil, print == fingerprint { return lines }
        // Reading costs ~80 ms of CPU; while words keep arriving, read at most every 0.6 s. Words
        // are final only after 1.5 s without change, so this loses nothing.
        if Date().timeIntervalSince(readAt) < 0.6 { return lines }
        fingerprint = print; readAt = Date()
        lines = await Self.recognize(image)
        return lines
    }
    private var readAt = Date.distantPast

    /// One request kept for the whole meeting on its own queue: the Swift `RecognizeTextRequest`
    /// rebuilt its Neural Engine plan for every frame and cost twice the CPU (measured 169 vs 79 ms).
    nonisolated(unsafe) private static let request: VNRecognizeTextRequest = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        return request
    }()
    private static let queue = DispatchQueue(label: "workscribe.caption-ocr", qos: .utility)

    private static func recognize(_ image: CGImage) async -> [ScreenTextLine] {
        await withCheckedContinuation { continuation in
            queue.async {
                try? VNImageRequestHandler(cgImage: image).perform([request])
                let lines = (request.results ?? []).compactMap { line -> ScreenTextLine? in
                    guard let text = line.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                    let box = line.boundingBox
                    return ScreenTextLine(text: text, x: box.origin.x, y: box.origin.y, width: box.width, height: box.height)
                }
                continuation.resume(returning: lines)
            }
        }
    }
}
