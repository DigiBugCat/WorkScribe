import AppKit
import SwiftUI
import Combine
import WorkScribeCore
import WorkScribePlaud
import UserNotifications

@main
enum Entry {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--mcp") { MCPServer().run() }
        else if let index = CommandLine.arguments.firstIndex(of: "--verify-voices"), index + 1 < CommandLine.arguments.count {
            do {
                let engine = VoiceEngine()
                let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                var vectors: [[Float]] = []
                for name in ["a1", "a2", "b1"] {
                    let samples = try await engine.readSamples(url: folder.appendingPathComponent(name + ".wav"), start: 0, duration: 4)
                    vectors.append(try await engine.embedding(samples: samples))
                }
                let data = try JSONSerialization.data(withJSONObject: ["dimension": vectors[0].count,
                    "same_speaker": VoiceMatching.cosine(vectors[0], vectors[1]),
                    "different_speaker": VoiceMatching.cosine(vectors[0], vectors[2])])
                FileHandle.standardOutput.write(data)
            } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
        }
        else if let index = CommandLine.arguments.firstIndex(of: "--verify-warm"), index + 1 < CommandLine.arguments.count {
            do { try await AudioVerification.verifyWarm(path: CommandLine.arguments[index + 1]) }
            catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
        }
        else if CommandLine.arguments.contains("--verify-detection") {
            let snapshot = CallDetector().snapshot()
            let data = try! JSONSerialization.data(withJSONObject: ["available": snapshot.available,
                "browser_permission": snapshot.browserPermission, "detected_app": snapshot.signal?.name as Any? ?? NSNull()])
            FileHandle.standardOutput.write(data)
        }
        else if let index = CommandLine.arguments.firstIndex(of: "--verify-combined"), index + 1 < CommandLine.arguments.count {
            do {
                async let title = TitleGenerator().generate(transcript: "We agreed to reduce staging compute costs by shutting down idle workers overnight and setting a monthly budget alert.")
                try await AudioVerification.run(path: CommandLine.arguments[index + 1])
                let generated = try await title
                FileHandle.standardError.write(Data("Combined title check: \(generated)\n".utf8))
            } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
        }
        else if let index = CommandLine.arguments.firstIndex(of: "--verify-import"), index + 1 < CommandLine.arguments.count {
            // Imports one WAV as a Note Pro recording into a throwaway library.
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("workscribe-import-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = AppModel(store: MeetingStore(root: root))
            let started = Date()
            model.importPlaud([PlaudSavedRecording(id: "verify:1790000000", audioURL: URL(fileURLWithPath: CommandLine.arguments[index + 1]),
                                                   recordedAt: Date(timeIntervalSince1970: 1_790_000_000))])
            while model.importActive || model.importTask != nil { try? await Task.sleep(nanoseconds: 200_000_000) }
            let seconds = Date().timeIntervalSince(started)
            await model.prepareToQuit()
            guard let entry = model.store.list().first else {
                FileHandle.standardError.write(Data("Import produced no meeting: \(model.importStatus ?? "")\n".utf8)); exit(1)
            }
            let files = (try? FileManager.default.contentsOfDirectory(atPath: model.store.directory(entry.id).path)) ?? []
            let result: [String: Any] = ["status": entry.status, "title": entry.title, "title_origin": entry.titleOrigin ?? "",
                "trigger": entry.recordingTrigger ?? "", "started_at": entry.startedAt.ISO8601Format(),
                "duration_seconds": entry.endedAt.map { $0.timeIntervalSince(entry.startedAt) } ?? -1,
                "segments": entry.segments.count, "speakers": Set(entry.segments.map(\.speaker)).sorted(),
                "text": entry.orderedSegments.map(\.text).joined(separator: " "), "files": files.sorted(),
                "import_status": model.importStatus ?? "", "elapsed_seconds": seconds]
            FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
        }
        else if let index = CommandLine.arguments.firstIndex(of: "--verify-audio"), index + 1 < CommandLine.arguments.count {
            do { try await AudioVerification.run(path: CommandLine.arguments[index + 1]) }
            catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
        }
        else if let index = CommandLine.arguments.firstIndex(of: "--verify-title"), index + 1 < CommandLine.arguments.count {
            do {
                let started = Date()
                func argument(_ key: String) -> String? {
                    guard let index = CommandLine.arguments.firstIndex(of: key), index + 1 < CommandLine.arguments.count else { return nil }
                    return CommandLine.arguments[index + 1]
                }
                let selected = argument("--title-model").flatMap(TitleModel.init(rawValue:)) ?? .bundled
                let result = try await TitleGenerator().generate(transcript: CommandLine.arguments[index + 1], model: selected, modelPath: argument("--model-path"))
                let data = try JSONSerialization.data(withJSONObject: ["title": result, "seconds": Date().timeIntervalSince(started)])
                FileHandle.standardOutput.write(data)
            } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
        }
        else {
            let application = NSApplication.shared
            let delegate = AppDelegate()
            application.delegate = delegate
            application.setActivationPolicy(.accessory)
            withExtendedLifetime(delegate) { application.run() }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var phaseObservation: AnyCancellable?
    private var elapsedTimer: Timer?
    // Owned here, not by a view, so a transfer survives the popover closing.
    private let plaud = PlaudHandoffController()
    private var plaudWindow: NSWindow?
    private var plaudObservation: AnyCancellable?
    private var transcriptWindow: NSPanel?
    private var hotKey: GlobalHotKey?
    private var shortcutObservation: AnyCancellable?
    private var qaWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Stable capture surface for synthetic UI testing; never enabled in the app bundle.
        if ProcessInfo.processInfo.environment["WORKSCRIBE_QA_WINDOW"] == "1" {
            let controller = NSHostingController(rootView: RecorderView(model: model, openPlaud: { [weak self] in self?.showPlaud() },
                                                                         openWindow: { [weak self] in self?.showTranscriptWindow() }))
            let window = NSWindow(contentViewController: controller)
            window.title = "WorkScribe QA"; window.styleMask = [.titled, .closable]
            window.center(); window.makeKeyAndOrderFront(nil); qaWindow = window
            NSApplication.shared.activate(ignoringOtherApps: true)
            model.activate(); return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "WorkScribe")
            button.toolTip = "WorkScribe"
            button.target = self
            button.action = #selector(togglePopover)
        }
        let hosting = NSHostingController(rootView: RecorderView(model: model, openPlaud: { [weak self] in self?.showPlaud() },
                                                                  openWindow: { [weak self] in self?.showTranscriptWindow() }))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.contentSize = hosting.view.fittingSize
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        if Notifier.available { UNUserNotificationCenter.current().delegate = self }
        shortcutObservation = model.$globalShortcut.receive(on: RunLoop.main).sink { [weak self] enabled in
            guard let self else { return }
            hotKey = enabled ? GlobalHotKey { [weak self] in Task { @MainActor in self?.toggleRecording() } } : nil
        }
        phaseObservation = model.$phase.combineLatest(model.$speechReady)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.refreshStatusItem() }
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.model.phase == "recording" { self?.refreshStatusItem() } }
        }
        model.activate()
        DispatchQueue.main.async { [weak self] in self?.showPopover() }
    }
    /// The popover is usually closed, so the icon has to say whether WorkScribe is recording.
    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        let symbol: String, description: String
        switch model.phase {
        case "recording": symbol = "record.circle.fill"; description = "WorkScribe is recording"
        case "error": symbol = "exclamationmark.triangle"; description = "WorkScribe couldn’t record"
        default: symbol = "waveform"; description = model.speechReady ? "WorkScribe" : "WorkScribe is getting ready"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        image?.isTemplate = model.phase != "recording"
        button.image = model.phase == "recording"
            ? image?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
            : image
        button.appearsDisabled = model.phase == "ready" && !model.speechReady
        if model.phase == "recording", let started = model.meeting?.startedAt {
            button.title = " " + AppModel.timestamp(Date().timeIntervalSince(started))
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
        button.toolTip = description
    }
    func showPlaud() {
        if plaudObservation == nil {
            // Saved recordings join the library as soon as they are verified.
            plaudObservation = plaud.$phase.receive(on: RunLoop.main).sink { [weak self] phase in
                guard let self, phase == "ready", !plaud.saved.isEmpty else { return }
                model.importPlaud(plaud.saved)
            }
        }
        if plaudWindow == nil {
            let view = PlaudHandoffView(device: plaud, model: model, close: { [weak self] in self?.plaudWindow?.performClose(nil) })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Note Pro"; window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false; window.delegate = self
            window.center(); plaudWindow = window
        }
        popover.performClose(nil)
        plaudWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender == plaudWindow else { return true }
        return !plaud.busy
    }
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) == plaudWindow else { return }
        plaud.disconnect()
    }
    /// Dragging the popover away turns it into a window that stays open.
    func popoverShouldDetach(_ popover: NSPopover) -> Bool { true }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    private func toggleRecording() {
        if model.phase == "recording" { Task { await model.stop() } }
        else if !model.busy && model.speechReady { Task { await model.start() } }
    }
    /// A resizable panel that floats above the call, for following along.
    func showTranscriptWindow() {
        if transcriptWindow == nil {
            let view = RecorderView(model: model, openPlaud: { [weak self] in self?.showPlaud() }, openWindow: nil, inWindow: true)
            let panel = NSPanel(contentViewController: NSHostingController(rootView: view))
            panel.title = "WorkScribe"
            panel.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            panel.level = .floating; panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.setContentSize(NSSize(width: 420, height: 640))
            panel.setFrameAutosaveName("WorkScribeTranscriptWindow")
            if !panel.setFrameUsingName("WorkScribeTranscriptWindow") { panel.center() }
            transcriptWindow = panel
        }
        popover.performClose(nil)
        transcriptWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }
    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let qaWindow { qaWindow.makeKeyAndOrderFront(nil) } else { showPopover() }; return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.phase == "starting" || model.phase == "finalizing" { return .terminateCancel }
        if plaud.busy { showPlaud(); return .terminateCancel }
        Task { @MainActor in await model.prepareToQuit(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
