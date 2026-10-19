import AppKit
import SwiftUI
import Combine
import WorkScribeCore
#if WORKSCRIBE_PLAUD
import WorkScribePlaud
#endif
import UserNotifications
import Carbon.HIToolbox

@main
enum Entry {
    @MainActor static func main() async {
        if let index = CommandLine.arguments.firstIndex(of: "--replay-transcript"), index + 1 < CommandLine.arguments.count,
           let mic = CommandLine.arguments.firstIndex(of: "--microphone"), mic + 1 < CommandLine.arguments.count {
            // Both tracks of one recording: system first, then the microphone on the same clock.
            func offset(_ key: String) -> Double? {
                guard let i = CommandLine.arguments.firstIndex(of: key), i + 1 < CommandLine.arguments.count else { return nil }
                return Double(CommandLine.arguments[i + 1])
            }
            do {
                try await TranscriptReplay.pair(system: CommandLine.arguments[index + 1], microphone: CommandLine.arguments[mic + 1],
                                                offsets: ["system": offset("--system-offset") ?? 0, "microphone": offset("--microphone-offset") ?? 0])
            } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--replay-transcript"), index + 1 < CommandLine.arguments.count {
            let paceIndex = CommandLine.arguments.firstIndex(of: "--pace")
            let pace = paceIndex.flatMap { $0 + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[$0 + 1]) : nil } ?? 1
            do { try await TranscriptReplay.run(path: CommandLine.arguments[index + 1], pace: pace) }
            catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--replay-caption-trace"), index + 1 < CommandLine.arguments.count {
            ZoomCaptions.replay(trace: URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--probe-zoom-captions"), index + 2 < CommandLine.arguments.count {
            await ZoomCaptions.probe(seconds: Double(CommandLine.arguments[index + 1]) ?? 60, output: URL(fileURLWithPath: CommandLine.arguments[index + 2]))
            exit(0)
        }
        if CommandLine.arguments.contains("--replay") {
            do { try await Replay.cli(CommandLine.arguments) }
            catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--doctor") {
            do {
                let code = try await Task.detached(priority: .utility) {
                    try RuntimeDoctor.run(checkOnly: CommandLine.arguments.contains("--check")) { line in
                        FileHandle.standardOutput.write(Data((line + "\n").utf8))
                    }
                }.value
                exit(code)
            } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
        }
        else if let position = CommandLine.arguments.firstIndex(of: "--bench-vectors"),
           position + 1 < CommandLine.arguments.count, let count = Int(CommandLine.arguments[position + 1]) {
            do {
                var result = try await Task.detached(priority: .utility) { try VectorBenchmark.run(count: count) }.value
                if let real = try await EmbeddingVectorBenchmark.runIfAvailable() { result["real_model"] = real }
                FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
                FileHandle.standardOutput.write(Data("\n".utf8))
            } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
        }
        else if CommandLine.arguments.contains("--bench-real-vectors") {
            do {
                let result = try await EmbeddingVectorBenchmark.runIfAvailable() ?? ["unavailable": true]
                FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
                FileHandle.standardOutput.write(Data("\n".utf8))
            } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
        }
        else if CommandLine.arguments.contains("--mcp") { MCPServer(embedder: CoreMLEmbedder.bundled()).run() }
        else if let i = CommandLine.arguments.firstIndex(of: "--bench-scenes"), CommandLine.arguments.count > i + 2 {
            do { try await ScreenSceneBenchmark.run(directory: URL(fileURLWithPath: CommandLine.arguments[i+1]), output: URL(fileURLWithPath: CommandLine.arguments[i+2])) }
            catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
        }
        else if CommandLine.arguments.contains("--verify-image-note") {
            do { try await ImageVerification.note() }
            catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
        }
        else if CommandLine.arguments.contains("--verify-images") {
            do { try await ImageVerification.run() }
            catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
        }
        else if CommandLine.arguments.contains("--verify-embedding") {
            do { try await EmbeddingVerification.run() }
            catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
        }
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
        else if let index = CommandLine.arguments.firstIndex(of: "--verify-screen") {
            let seconds = index + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[index + 1]) ?? 10 : 10
            do { try await ScreenVerification.run(seconds: min(max(seconds, 1), 120)) }
            catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
        }
        else if CommandLine.arguments.contains("--serve-api-for-tests") {
            do { try await APIVerification.serveForTests() }
            catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
        }
        else if CommandLine.arguments.contains("--verify-purge") {
            do { try await PurgeVerification.run() }
            catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
        }
        else if CommandLine.arguments.contains("--verify-api") {
            do { try await APIVerification.run() }
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
            #if WORKSCRIBE_PLAUD
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
            #else
            FileHandle.standardError.write(Data("--verify-import requires WORKSCRIBE_PLAUD=1 at build time.\n".utf8)); exit(1)
            #endif
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
                if let name = argument("--title-model"), GeneratorModel(rawValue: name) == nil {
                    throw CaptureError.message("Only the bundled Gemma 4 E4B model is supported")
                }
                let selected = GeneratorModel.bundled
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
    private var runtimeStatus: String?
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var phaseObservation: AnyCancellable?
    private var elapsedTimer: Timer?
    // Owned here, not by a view, so a transfer survives the popover closing.
    #if WORKSCRIBE_PLAUD
    private let plaud = PlaudHandoffController()
    private var plaudWindow: NSWindow?
    private var plaudObservation: AnyCancellable?
    #endif
    private var transcriptWindow: NSPanel?
    private var hotKey: GlobalHotKey?
    private var shortcutObservation: AnyCancellable?
    private var qaWindow: NSWindow?
    private var search: SearchHookup?
    private var vault: VaultHookup?
    private lazy var ask = AskService(model: model)
    private lazy var api = LocalAPI(model: model, ask: ask)
    private lazy var quickAsk = QuickAskController(ask: ask, model: model)
    private var quickAskHotKey: GlobalHotKey?
    private var observers: [NSObjectProtocol] = []

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
        // ⌥⌘K quick ask, from any app (also while recording: the live call is searched first).
        quickAskHotKey = UserDefaults.standard.object(forKey: "quickAskShortcut") as? Bool ?? true
            ? GlobalHotKey(keyCode: kVK_ANSI_K, modifiers: cmdKey | optionKey, id: 2) { [weak self] in
                Task { @MainActor in self?.quickAsk.toggle() } }
            : nil
        quickAsk.openLink = { [weak self] link in self?.openLink(link) }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .workScribeShowQuickAsk, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil); self?.quickAsk.show() }
        })
        phaseObservation = Publishers.CombineLatest4(model.$phase, model.$speechReady, model.$screenAccess, model.$includeSystemAudio)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in DispatchQueue.main.async { self?.refreshStatusItem() } }
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.model.phase == "recording" { self?.refreshStatusItem() } }
        }
        model.activate()
        Task { [weak self] in
            self?.runtimeStatus = "Getting models ready…"
            self?.refreshStatusItem()
            let code = try? await Task.detached(priority: .utility) {
                try RuntimeDoctor.run { [weak self] line in
                    Task { @MainActor in
                        self?.runtimeStatus = line.hasPrefix("Getting models ready") ? line.components(separatedBy: " · ").prefix(2).joined(separator: " · ") : "Getting models ready…"
                        self?.refreshStatusItem()
                    }
                }
            }.value
            self?.runtimeStatus = code == 0 ? nil : "Models need attention · run --doctor"
            self?.refreshStatusItem()
            // Recover each capability independently even if an optional repair failed.
            if let model = self?.model {
                try? await model.prepareSpeech()
                if model.speechReady && model.message.hasPrefix("Couldn’t prepare speech:") {
                    model.phase = "ready"
                    model.message = "Record locally. Ask questions as the conversation unfolds."
                }
            }
            await self?.search?.service.refreshRuntime()
        }
        // Opening/migrating a multi-million-chunk index must not stall app launch or recording.
        Task { [weak self, store = model.store] in
            let service = await Task.detached(priority: .utility) { IndexService.make(store: store) }.value
            guard let self else { return }
            if let service {
                model.lineIndex = await service.evidenceIndex()
                self.search = SearchHookup(model: model, service: service)
                Enrich.embedderSource = { [weak service] in await service?.queryEmbedder ?? Enrich.standaloneEmbedder }
                NoteEnhancementScheduler.shared.enhancer = Enrich(indexSource: { [weak service] in await service?.evidenceIndex() })
            }
            self.vault = VaultHookup(model: model, index: service)
            self.ask.index = service
            let retention = MeetingRetention(model: model, ask: ask, vault: self.vault!.store, index: service)
            model.retentionService = retention
            retention.start()
        }
        // The local API for the Obsidian plugin (docs/api/local-api.md).
        if ProcessInfo.processInfo.environment["WORKSCRIBE_DISABLE_API"] != "1" {
            Task { [weak self] in
                guard let self else { return }
                do { try await api.start() }
                catch { model.message = "Couldn’t start the local API: \(error.localizedDescription)" }
            }
        }
        if ProcessInfo.processInfo.environment["WORKSCRIBE_SHOW_QUICK_ASK"] == "1" {
            // Verification hook: open quick ask instead of the popover.
            DispatchQueue.main.async { [weak self] in self?.quickAsk.show() }
        } else {
            DispatchQueue.main.async { [weak self] in self?.showPopover() }
        }
    }
    /// Citations and links: meetings open in the floating transcript at the moment; files at their page or time.
    private func openLink(_ link: WorkScribeLink) {
        model.open(link)
        if case .meeting = link { showTranscriptWindow() }
    }
    /// workscribe:// links from MCP clients, notes and search results.
    func application(_ application: NSApplication, open urls: [URL]) {
        for link in urls.compactMap(WorkScribeLink.init(url:)) { openLink(link) }
    }
    /// The popover is usually closed, so the icon has to say whether WorkScribe is recording.
    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        let symbol: String, description: String
        switch model.phase {
        case "recording": symbol = "record.circle.fill"; description = "WorkScribe is recording"
        case "error": symbol = "exclamationmark.triangle"; description = "WorkScribe couldn’t record"
        case _ where model.includeSystemAudio && !model.screenAccess:
            symbol = "exclamationmark.triangle"; description = "WorkScribe needs Screen Recording permission for system audio"
        default: symbol = "waveform"; description = model.speechReady ? "WorkScribe" : "WorkScribe is getting ready"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        let attention = symbol == "exclamationmark.triangle"
        image?.isTemplate = model.phase != "recording" && !attention
        // Trust-first states: recording = the one vermilion dot; needs attention = ochre.
        button.image = model.phase == "recording"
            ? image?.withSymbolConfiguration(.init(paletteColors: [Theme.vermilionNS]))
            : attention ? image?.withSymbolConfiguration(.init(paletteColors: [Theme.ochreNS])) : image
        button.appearsDisabled = model.phase == "ready" && !model.speechReady
        if model.phase == "recording", let started = model.meeting?.startedAt {
            button.title = " " + AppModel.timestamp(Date().timeIntervalSince(started))
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.imagePosition = .imageLeading
        } else {
            button.title = runtimeStatus.map { " " + $0 } ?? ""
            button.imagePosition = runtimeStatus == nil ? .imageOnly : .imageLeading
        }
        button.toolTip = runtimeStatus ?? description
    }
    func showPlaud() {
        #if WORKSCRIBE_PLAUD
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
        #endif
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        #if WORKSCRIBE_PLAUD
        guard sender == plaudWindow else { return true }
        return !plaud.busy
        #else
        return true
        #endif
    }
    func windowWillClose(_ notification: Notification) {
        #if WORKSCRIBE_PLAUD
        guard (notification.object as? NSWindow) == plaudWindow else { return }
        plaud.disconnect()
        #endif
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
    private let recordingQuit = RecordingQuit()
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if WORKSCRIBE_PLAUD
        let deviceBusy = plaud.busy
        if deviceBusy { showPlaud() }
        #else
        let deviceBusy = false
        #endif
        return recordingQuit.request(phase: model.phase, blocked: deviceBusy, save: { [self] in
            await model.prepareToQuit()
        }, complete: { [self] in
            // Keep API, vault and capture ownership intact until the save has settled.
            vault?.stop(); api.stop()
            sender.reply(toApplicationShouldTerminate: true)
        })
    }
}
