import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit
@preconcurrency import Vision
import WorkScribeCore

/// Reads ONE app's focused window: its accessibility text, or a picture of that window.
///
/// Never the display. `ScreenWatch` decides which app may be read; this type can only read the app
/// it is given, so text or pixels of whatever else has come to the front cannot end up in a reading.
enum ScreenReader {
    struct Limits {
        /// Accessibility elements visited per read.
        var elements = 1_500
        var characters = 12_000
        /// Wall-clock budget for one accessibility walk. A hung app must not hold up reading.
        var seconds = 0.35
        /// How long any single accessibility message may take.
        var messageTimeout: Float = 0.25
        /// Fewer words than this from accessibility: the window draws its own content, look at it instead.
        var thinWords = 12
        var pictureWidth = 1_920
        /// How long a window's text waits for the vector of its picture before going on without it.
        var vectorWait = 1.0
    }

    static var accessibilityAllowed: Bool { AXIsProcessTrusted() }
    /// Shows the system's "allow WorkScribe to control this computer" prompt (reading window text needs it).
    static func askForAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    static var picturesAllowed: Bool { CGPreflightScreenCaptureAccess() }

    /// The title of `pid`'s focused window, when accessibility is allowed and the app answers.
    static func windowTitle(pid: pid_t, limits: Limits = Limits()) -> String? {
        guard accessibilityAllowed, let window = focusedWindow(pid: pid, limits: limits) else {
            return picturesAllowed ? titleFromWindowList(pid: pid) : nil
        }
        return string(window, kAXTitleAttribute)
    }

    struct Text { var title: String?; var text: String; var url: String? }

    /// The readable text of `pid`'s focused window, top to bottom, without anything typed into a secure field.
    static func accessibilityText(pid: pid_t, limits: Limits = Limits()) -> Text? {
        guard accessibilityAllowed, let window = focusedWindow(pid: pid, limits: limits) else { return nil }
        let deadline = CFAbsoluteTimeGetCurrent() + limits.seconds
        var pieces: [String] = [], characters = 0, visited = 0, url: String?
        var stack: [AXUIElement] = [window]
        while let element = stack.popLast(), visited < limits.elements, characters < limits.characters,
              CFAbsoluteTimeGetCurrent() < deadline {
            visited += 1
            let role = string(element, kAXRoleAttribute) ?? ""
            // What is typed into a password field is not text to keep, whatever the app exposes.
            if role == "AXSecureTextField" || string(element, kAXSubroleAttribute) == "AXSecureTextField" { continue }
            if role == "AXWebArea", url == nil { url = link(element, "AXURL") }
            if let text = readable(element, role: role), text != pieces.last {
                pieces.append(text); characters += text.count
            }
            // Visible children when the element says which are (tables, lists, outlines): off-screen rows are not on screen.
            let children = elements(element, kAXVisibleChildrenAttribute) ?? elements(element, kAXChildrenAttribute) ?? []
            stack.append(contentsOf: children.reversed())
        }
        let title = string(window, kAXTitleAttribute)
        return Text(title: title, text: pieces.joined(separator: "\n"), url: url ?? string(window, kAXDocumentAttribute))
    }

    /// A picture of `pid`'s largest ordinary window (the one titled `title` when there is one).
    static func picture(pid: pid_t, title: String?, limits: Limits = Limits()) async -> CGImage? {
        guard picturesAllowed, let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return nil }
        let candidates = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.isOnScreen && $0.frame.width >= 200 && $0.frame.height >= 150
        }
        guard let window = candidates.first(where: { title != nil && $0.title == title })
                ?? candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let pixels = CGSize(width: window.frame.width * scale, height: window.frame.height * scale)
        let factor = min(1, CGFloat(limits.pictureWidth) / max(pixels.width, 1))
        let configuration = SCStreamConfiguration()
        configuration.width = max(2, Int(pixels.width * factor)); configuration.height = max(2, Int(pixels.height * factor))
        configuration.showsCursor = false; configuration.capturesAudio = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    // MARK: Accessibility plumbing

    private static func focusedWindow(pid: pid_t, limits: Limits) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, limits.messageTimeout)
        return element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute)
    }

    /// The words an element shows, for the kinds of element that show words.
    private static func readable(_ element: AXUIElement, role: String) -> String? {
        let value: String?
        switch role {
        case "AXStaticText", "AXTextArea", "AXTextField", "AXComboBox", "AXHeading", "AXCell":
            value = string(element, kAXValueAttribute) ?? string(element, kAXTitleAttribute)
        case "AXLink", "AXButton", "AXMenuButton", "AXPopUpButton", "AXTab", "AXRadioButton", "AXCheckBox", "AXImage":
            value = string(element, kAXTitleAttribute) ?? string(element, kAXDescriptionAttribute)
        default: value = nil
        }
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(4_000))
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }
    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let text = copy(element, attribute) as? String, !text.isEmpty else { return nil }
        return text
    }
    private static func link(_ element: AXUIElement, _ attribute: String) -> String? {
        (copy(element, attribute) as? URL)?.absoluteString ?? (copy(element, attribute) as? String)
    }
    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        guard let values = copy(element, attribute) as? [AXUIElement], !values.isEmpty else { return nil }
        return values
    }

    private static func titleFromWindowList(pid: pid_t) -> String? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.first { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .flatMap { $0[kCGWindowName as String] as? String }.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Vision OCR for a window picture: document recognition (paragraphs, tables, lists) with line boxes,
/// falling back to plain text recognition.
enum ScreenOCR {
    static func read(_ image: CGImage) async -> (text: String, lines: [ScreenTextLine]) {
        do {
            let documents = try await RecognizeDocumentsRequest().perform(on: image)
            let lines = documents.flatMap { $0.document.text.lines }
            if !lines.isEmpty { return convert(lines) }
            let text = documents.map { $0.document.text.transcript }.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (text, []) }
        } catch {}
        do {
            var request = RecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            return convert(try await request.perform(on: image))
        } catch { return ("", []) }
    }

    private static func convert(_ observations: [RecognizedTextObservation]) -> (text: String, lines: [ScreenTextLine]) {
        let lines = observations.compactMap { line -> ScreenTextLine? in
            let text = line.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let box = line.boundingBox
            return ScreenTextLine(text: text, x: box.origin.x, y: box.origin.y, width: box.width, height: box.height)
        }
        return (lines.map(\.text).joined(separator: "\n"), lines)
    }
}
