import AppKit
import AVKit
import PDFKit

/// Opens a cited file at its moment: a PDF at the page, audio or video at the time. Anything else (or a file without
/// a page or time) opens in its default app.
@MainActor
enum FileMomentViewer {
    private static var windows: [NSWindow] = []

    static func open(_ url: URL, page: Int?, seconds: Double?) {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf", let page, let document = PDFDocument(url: url) {
            let view = PDFView()
            view.document = document; view.autoScales = true
            if let target = document.page(at: max(0, min(page - 1, document.pageCount - 1))) { view.go(to: target) }
            show(view, title: "\(url.lastPathComponent) · p.\(page)", size: NSSize(width: 720, height: 900))
            return
        }
        let media = FolderRulesKinds.media.contains(ext)
        if media, let seconds {
            let player = AVPlayer(url: url)
            let view = AVPlayerView(); view.player = player; view.controlsStyle = .floating
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
            show(view, title: "\(url.lastPathComponent) · \(AppModel.timestamp(seconds))",
                 size: FolderRulesKinds.audio.contains(ext) ? NSSize(width: 520, height: 120) : NSSize(width: 800, height: 480))
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static func show(_ view: NSView, title: String, size: NSSize) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = title; window.contentView = view; window.isReleasedWhenClosed = false
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        windows.removeAll { !$0.isVisible }
        windows.append(window)
    }
}

private enum FolderRulesKinds {
    static let audio: Set<String> = ["wav", "m4a", "mp3", "aac", "aif", "aiff", "caf", "flac"]
    static let media: Set<String> = audio.union(["mov", "mp4", "m4v"])
}
