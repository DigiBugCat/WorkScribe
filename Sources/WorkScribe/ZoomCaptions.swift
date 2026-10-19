import AppKit
import ApplicationServices
import WorkScribeCore

/// Reads Zoom's live captions through macOS Accessibility. Nothing here records audio:
/// the meeting platform has already turned speech into text, and we only observe it.
enum ZoomCaptions {
    static let bundleID = "us.zoom.xos"

    /// One readable text element in Zoom's meeting window.
    struct TextElement: Codable, Equatable {
        var role: String
        var value: String
        var x: Double, y: Double, width: Double, height: Double
    }

    static var trusted: Bool { AXIsProcessTrusted() }

    /// Asks macOS to show the Accessibility prompt for WorkScribe. Returns whether access is already granted.
    @discardableResult static func requestAccess() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    /// Every Accessibility read goes through this queue, never the main thread: Zoom can take
    /// seconds to answer while it is busy, and each call is capped at half a second.
    private static let queue = DispatchQueue(label: "workscribe.zoom-captions", qos: .userInitiated)

    private static func application() -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        return element
    }

    private static func allWindows() -> [AXUIElement] { application().map(windows) ?? [] }

    static func meetingWindow() -> AXUIElement? {
        allWindows().first { (attribute($0, kAXTitleAttribute) as? String) == "Zoom Meeting" }
    }

    private static func label(_ element: AXUIElement) -> String {
        [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
            .compactMap { attribute(element, $0) as? String }.joined(separator: " ").lowercased()
    }

    /// Where Zoom is showing captions right now, and whether it is in a meeting at all.
    struct Place {
        var meeting: AXUIElement?
        var containers: [AXUIElement] = []
        var windows: [String] = []
        var inMeeting: Bool { meeting != nil || !containers.isEmpty || windows.contains { $0.hasPrefix("zoom share") } }
    }

    /// Zoom labels its caption area "Closed caption subtitles". While you share, that area is its
    /// own small floating window, found from the window list alone. Otherwise it sits inside the
    /// meeting window; that search is remembered for two seconds while the element stays alive.
    nonisolated(unsafe) private static var cachedInner: (elements: [AXUIElement], at: Date) = ([], .distantPast)

    private static func locate() -> Place {
        let windows = allWindows()
        var place = Place(windows: windows.compactMap { attribute($0, kAXTitleAttribute) as? String })
        place.meeting = windows.first { (attribute($0, kAXTitleAttribute) as? String) == "Zoom Meeting" }
        place.containers = windows.filter { label($0).contains("caption subtitles") }
        guard place.containers.isEmpty, let meeting = place.meeting else { return place }
        let alive = !cachedInner.elements.isEmpty && cachedInner.elements.allSatisfy { attribute($0, kAXRoleAttribute) != nil }
        if alive, Date().timeIntervalSince(cachedInner.at) < 2 { place.containers = cachedInner.elements; return place }
        var stack = [meeting], visited = 0
        while let element = stack.popLast(), visited < 2000 {
            visited += 1
            if label(element).contains("caption subtitles") { place.containers.append(element); continue }
            stack.append(contentsOf: children(element))
        }
        cachedInner = (place.containers, Date())
        return place
    }

    /// One look at Zoom: whether it is in a meeting, the caption blocks on screen (nil when there is
    /// nowhere to read them), and an optional trace row for studying new Zoom versions.
    struct Reading: @unchecked Sendable {
        var inMeeting = false
        var looks: [CaptionStream.Look]?
        var trace: Data?
        /// Captions are drawn here without Accessibility text, so they are read from the screen.
        var drawn: CGRect?
        /// Reading drawn captions needs Screen Recording access.
        var needsScreenAccess = false
        /// Zoom's captions are switched on: their area or its "Captions are on" placeholder is showing.
        var captionsOn = false
        fileprivate var row: [String: Any]?
    }

    static func read(at: Double = 0, trace: Bool = false) async -> Reading {
        var reading = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: readNow(at: at, trace: trace)) }
        }
        if let box = reading.drawn {
            reading.needsScreenAccess = !CGPreflightScreenCaptureAccess()
            let lines = await CaptionOCR.shared.lines(in: box, bundleID: bundleID)
            reading.looks = CaptionLayout.looks(from: lines, chrome: chrome)
            reading.row?["ocr"] = lines.map { ["text": $0.text, "y": $0.y, "h": $0.height] }
        }
        if let row = reading.row { reading.trace = (try? JSONSerialization.data(withJSONObject: row)).map { $0 + Data([10]) } }
        reading.row = nil
        return reading
    }

    nonisolated(unsafe) private static var lastDump = -10.0
    private static func readNow(at: Double, trace: Bool) -> Reading {
        guard AXIsProcessTrusted() else { return Reading() }
        let place = locate()
        var reading = Reading(inMeeting: place.inMeeting)
        let all: [TextElement]
        if !place.containers.isEmpty { all = place.containers.flatMap { texts(in: $0) }.sorted { ($0.y, $0.x) < ($1.y, $1.x) } }
        else if let meeting = place.meeting { all = texts(in: meeting) }
        else { all = [] }
        if place.meeting != nil || !place.containers.isEmpty { reading.looks = blocks(from: all) }
        reading.captionsOn = !place.containers.isEmpty
            || all.contains { $0.role == "AXStaticText" && chrome.contains($0.value.trimmingCharacters(in: .whitespacesAndNewlines)) && $0.value.contains(" on") }
        // A caption window with no text of its own: Zoom draws the words (while sharing).
        if let window = place.containers.first(where: { attribute($0, kAXRoleAttribute) as? String == kAXWindowRole }),
           !all.contains(where: { $0.role == "AXStaticText" }) {
            reading.drawn = frame(window)
        }
        if trace {
            var row: [String: Any] = ["t": at, "windows": place.windows, "containers": place.containers.count,
                                      "texts": all.map { ["role": $0.role, "value": $0.value, "y": $0.y, "h": $0.height] }]
            if UserDefaults.standard.bool(forKey: "captionTraceDump"), at - lastDump > 5 {
                lastDump = at
                row["dump"] = place.containers.map { dump($0, depth: 0) }
            }
            reading.row = row
        }
        return reading
    }

    /// Every text-bearing element in the meeting window, top to bottom.
    static func texts(in window: AXUIElement, limit: Int = 400) -> [TextElement] {
        var out: [TextElement] = [], stack = [window]
        while let element = stack.popLast(), out.count < limit {
            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            let value = (attribute(element, kAXValueAttribute) as? String)
                ?? (attribute(element, kAXTitleAttribute) as? String)
                ?? (attribute(element, kAXDescriptionAttribute) as? String) ?? ""
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let frame = Self.frame(element)
                out.append(TextElement(role: role, value: value, x: frame.minX, y: frame.minY, width: frame.width, height: frame.height))
            }
            stack.append(contentsOf: children(element).reversed())
        }
        return out.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
    }

    /// Words Zoom shows in the caption area that are its own interface, not speech.
    static let chrome: Set<String> = ["Captions are on", "Captions are off", "Live transcription is on"]

    /// Pairs Zoom's name labels with the caption paragraphs beneath them. Labels are one short line
    /// (18 pt; even a one-line caption is taller) and are never speech. Each paragraph takes the closest
    /// label just above it by position, not by order: while the list scrolls, Accessibility can briefly
    /// report a label below its own paragraph.
    static func blocks(from all: [TextElement]) -> [CaptionStream.Look] {
        let items = all.filter { $0.role == "AXStaticText" && !chrome.contains($0.value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let isLabel = { (item: TextElement) in item.height <= 22 && item.value.trimmingCharacters(in: .whitespacesAndNewlines).count <= 60 }
        var labels = items.filter(isLabel)
        return items.filter { !isLabel($0) }.sorted { $0.y < $1.y }.map { paragraph in
            let gap = { (label: TextElement) in abs(paragraph.y - (label.y + label.height)) }
            var speaker: String?
            if let best = labels.indices.min(by: { gap(labels[$0]) < gap(labels[$1]) }), gap(labels[best]) <= 40 {
                speaker = labels[best].value.trimmingCharacters(in: .whitespacesAndNewlines)
                labels.remove(at: best)
            }
            return .init(speaker: speaker, text: paragraph.value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Debug: the element and its subtree, with every attribute name it reports.
    private static func dump(_ element: AXUIElement, depth: Int) -> [String: Any] {
        var names: CFArray?
        AXUIElementCopyAttributeNames(element, &names)
        let list = (names as? [String]) ?? []
        var node: [String: Any] = ["attrs": list, "frame": "\(frame(element))"]
        for name in list where ![kAXChildrenAttribute, "AXParent", "AXTopLevelUIElement", "AXWindow"].contains(name) {
            if let v = attribute(element, name) {
                if let s = v as? String { node[name] = String(s.prefix(200)) }
                else if let n = v as? NSNumber { node[name] = n }
                else if let a = v as? [AnyObject] { node[name] = "[\(a.count)]" }
            }
        }
        if depth < 12 { node["children"] = children(element).prefix(60).map { dump($0, depth: depth + 1) } }
        return node
    }
    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private static func windows(_ app: AXUIElement) -> [AXUIElement] { (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] }
    private static func children(_ element: AXUIElement) -> [AXUIElement] { (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
    private static func frame(_ element: AXUIElement) -> CGRect {
        var origin = CGPoint.zero, size = CGSize.zero
        if let value = attribute(element, kAXPositionAttribute) { AXValueGetValue(value as! AXValue, .cgPoint, &origin) }
        if let value = attribute(element, kAXSizeAttribute) { AXValueGetValue(value as! AXValue, .cgSize, &size) }
        return CGRect(origin: origin, size: size)
    }

    /// `--replay-caption-trace TRACE.jsonl`: feeds a recorded caption trace through the same
    /// pairing and stream the app uses, and prints the final segments.
    static func replay(trace: URL) {
        guard let text = try? String(contentsOf: trace, encoding: .utf8) else { print("Couldn’t read \(trace.path)"); return }
        var stream = CaptionStream(), last = 0.0
        func show(_ events: [[String: Any]], _ t: Double) {
            for e in events where e["type"] as? String == "transcript.completed" {
                let speaker = (e["words"] as? [[String: Any]])?.first?["speaker"] as? Int ?? 0
                print(String(format: "%6.1f", t), speaker == 0 ? "?" : stream.names[speaker - 1], "|", e["transcript"] as? String ?? "")
            }
        }
        for line in text.split(separator: "\n") {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let t = row["t"] as? Double,
                  let raw = row["texts"] as? [[String: Any]] else { continue }
            let looks: [CaptionStream.Look]
            if let ocr = row["ocr"] as? [[String: Any]] {
                looks = CaptionLayout.looks(from: ocr.map { ScreenTextLine(text: $0["text"] as? String ?? "", x: 0, y: $0["y"] as? Double ?? 0,
                                                                           width: 0, height: $0["h"] as? Double ?? 0) }, chrome: chrome)
            } else {
                looks = blocks(from: raw.map { TextElement(role: $0["role"] as? String ?? "", value: $0["value"] as? String ?? "", x: 0,
                                                           y: $0["y"] as? Double ?? 0, width: 0, height: $0["h"] as? Double ?? 0) })
            }
            show(stream.observe(looks, at: t), t); last = t
        }
        show(stream.flush(at: last + 0.25), last + 0.25)
    }

    /// `--probe-zoom-captions SECONDS OUT.jsonl`: records each change in the meeting window's
    /// text so the caption structure can be studied. Prompts for Accessibility when needed.
    static func probe(seconds: Double, output: URL) async {
        let handle: FileHandle
        FileManager.default.createFile(atPath: output.path, contents: nil)
        do { handle = try FileHandle(forWritingTo: output) } catch { print("Couldn’t open \(output.path)"); return }
        func write(_ object: [String: Any]) {
            if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) { handle.write(data + Data([10])) }
        }
        guard requestAccess() else {
            write(["event": "needs-accessibility"]); print("WorkScribe needs Accessibility access to read Zoom’s captions."); return
        }
        let start = Date()
        var last: [TextElement] = []
        while Date().timeIntervalSince(start) < seconds {
            if let window = meetingWindow() {
                let now = texts(in: window)
                if now != last {
                    write(["t": Date().timeIntervalSince(start),
                           "texts": now.map { ["role": $0.role, "value": $0.value, "x": $0.x, "y": $0.y, "w": $0.width, "h": $0.height] }])
                    last = now
                }
            } else if !last.isEmpty || Date().timeIntervalSince(start) < 0.3 {
                write(["t": Date().timeIntervalSince(start), "event": "no-meeting-window"]); last = []
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        try? handle.close()
    }
}
