import AppKit
import Foundation
import WorkScribeCore
import WorkScribePlaud

@MainActor
final class AppModel: ObservableObject {
    @Published var phase = "ready"
    @Published var message = "Record locally. Ask questions as the conversation unfolds."
    @Published var meeting: Meeting?
    @Published var library: [Meeting] = []
    @Published var autoRecordCalls = ProcessInfo.processInfo.environment["WORKSCRIBE_DISABLE_AUTORECORD"] == "1"
        ? false : (UserDefaults.standard.object(forKey: "autoRecordCalls") as? Bool ?? true) {
        didSet { UserDefaults.standard.set(autoRecordCalls, forKey: "autoRecordCalls"); if !autoRecordCalls { autoPolicy.reset() } }
    }
    @Published var autoStatus = "Watching for calls"
    @Published var namingIDs: Set<String> = []
    @Published var titleError: [String: String] = [:]
    @Published var includeSystemAudio = true
    @Published var selectedID: String?
    @Published var speechReady = false
    @Published var speechStatus = "Warming speech engine…"
    let store: MeetingStore
    let runtime = SpeechRuntime()
    @Published var voices: [VoiceProfile] = []
    @Published var voiceStatus = "Name a speaker to remember their voice"
    @Published var voiceJobs: Set<String> = []
    @Published var speakerUndo: [String: SpeakerUndo] = [:]
    var voiceGeneration = 0
    var voiceTaskTokens: [String: UUID] = [:]
    var voiceTasks: [String: Task<Void, Never>] = [:]
    let voiceEngine: any VoiceExtracting
    let voiceStore: VoiceStore
    private var capture: AudioCapture?
    private var connections: [String: SpeechConnection] = [:]
    private var pumps: [Task<Void, Never>] = []
    private var offsets: [String: Double] = [:]
    private var ends: [String: Double] = [:]
    private var errorText: String?
    private let titleGenerator: any TitleGenerating
    private var liveTitleAttempted: Set<String> = []
    private var titleJobs: [String: Task<Void, Never>] = [:]
    private var finalTitlesPending: Set<String> = []
    private let callDetector = CallDetector()
    private var autoPolicy = AutoRecordPolicy()
    private var monitor: Task<Void, Never>?
    private var warmupTask: Task<Void, Error>?
    // Note Pro recordings waiting to be transcribed into the library (PlaudImport.swift).
    @Published var importQueue: [PlaudSavedRecording] = []
    @Published var importStatus: String?
    var importDone = 0, importTotal = 0, importFailures = 0
    var importTask: Task<Void, Never>?
    var visibleMeeting: Meeting? {
        if let selectedID, selectedID != meeting?.id { return library.first { $0.id == selectedID } }
        return meeting ?? library.first
    }
    var busy: Bool { phase == "starting" || phase == "recording" || phase == "finalizing" || phase == "preview" }
    init(store: MeetingStore = MeetingStore(), titleGenerator: any TitleGenerating = TitleGenerator(), voiceEngine: any VoiceExtracting = VoiceEngine()) {
        self.store = store; self.titleGenerator = titleGenerator
        self.voiceEngine = voiceEngine; self.voiceStore = VoiceStore(root: store.root)
        do { voices = try voiceStore.load() }
        catch { voiceStatus = "Couldn’t read saved voices: \(error.localizedDescription)" }
        // A previous app crash must not leave an apparently live meeting in MCP.
        for var old in store.list() where old.status == "recording" || old.status == "finalizing" {
            old.status = "interrupted"; old.failure = "Recording was interrupted before finalization. Saved audio and transcript retained."
            try? store.save(old)
        }
        library = store.list()
    }
    func activate() {
        guard monitor == nil else { return }
        if ProcessInfo.processInfo.environment["WORKSCRIBE_CAPTION_DEMO"] == "1" {
            autoRecordCalls = false
            monitor = Task { await runCaptionDemo() }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do { try await prepareSpeech() }
            catch {
                if !busy { phase = "error"; message = "Couldn’t prepare speech: \(error.localizedDescription). Start recording to retry." }
            }
        }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                self?.checkCall()
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }
        for entry in library.prefix(10) where entry.status == "complete" && entry.sourceOffsets != nil && entry.speakerSuggestions == nil {
            analyzeVoices(id: entry.id)
        }
        for entry in library where entry.status == "complete" && entry.titleOrigin == "pending" {
            scheduleTitle(id: entry.id, final: true)
        }
    }
    private func checkCall() {
        guard autoRecordCalls else { autoStatus = "Automatic recording off"; return }
        guard speechReady else { return }
        let snapshot = callDetector.snapshot()
        guard snapshot.available else { autoStatus = "Call detection unavailable; use Start recording"; return }
        autoStatus = snapshot.signal.map { "Call activity: \($0.name)" }
            ?? (snapshot.browserPermission ? "Watching for calls" : "Watching call apps · browser detection needs Screen Recording access")
        let automatic = phase == "recording" && meeting?.recordingTrigger?.hasPrefix("call:") == true
        switch autoPolicy.update(callActive: snapshot.signal != nil, enabled: true, busy: busy,
                                automaticallyRecording: automatic, now: Date()) {
        case .start:
            if let signal = snapshot.signal { Task { await start(trigger: signal.name) } }
        case .stop: Task { await stop(userInitiated: false) }
        case .none: break
        }
    }
    func prepareSpeech() async throws {
        if speechReady { return }
        if warmupTask == nil {
            speechStatus = "Warming speech engine…"
            warmupTask = Task { try await runtime.warmUp() }
        }
        do {
            try await warmupTask!.value
            speechReady = true; speechStatus = "Speech engine warm and ready"
        } catch {
            warmupTask = nil; speechReady = false; speechStatus = "Speech engine unavailable"
            throw error
        }
    }
    func start(trigger: String? = nil) async {
        guard !busy else { return }
        phase = "starting"; message = "Starting recording…"; errorText = nil
        offsets = [:]; ends = [:]
        await pauseImports()
        do {
            try await prepareSpeech()
            meeting = Meeting(title: "Recording · \(Date().formatted(date: .abbreviated, time: .shortened))", titleOrigin: "pending")
            meeting?.recordingTrigger = trigger.map { "call:\($0)" } ?? "manual"
            selectedID = meeting?.id
            try save()
            let folder = try store.directory(meeting!.id)
            let mic = try AudioTrack(url: folder.appendingPathComponent("microphone.wav"))
            let system = includeSystemAudio ? try AudioTrack(url: folder.appendingPathComponent("system.wav")) : nil
            for (source, track) in [("microphone", mic), ("system", system)].compactMap({ source, track in track.map { (source, $0) } }) {
                let connection = SpeechConnection(runtime: runtime)
                connection.onEvent = { [weak self] event in self?.consume(event, source: source) }
                connection.onFailure = { [weak self] error in Task { await self?.fail(error) } }
                connections[source] = connection
                try await connection.connect()
                pumps.append(Task { [weak self] in
                    do {
                        for try await data in track.stream {
                            guard let self else { return }
                            if offsets[source] == nil {
                                offsets[source] = Date().timeIntervalSince(meeting!.startedAt)
                                if meeting?.sourceOffsets == nil { meeting?.sourceOffsets = [:] }
                                meeting?.sourceOffsets?[source] = offsets[source]
                            }
                            try await connection.write(data)
                        }
                    } catch { Task { await self?.fail(error) } }
                })
            }
            let capture = AudioCapture(); self.capture = capture
            capture.onFailure = { [weak self] error in Task { @MainActor in await self?.fail(error) } }
            message = "Waiting for audio permissions…"
            try await capture.start(microphone: mic, system: system)
            if let errorText { throw CaptureError.message(errorText) }
            phase = "recording"; message = trigger.map { "Automatically recording \($0) · saved on this Mac" } ?? "Recording on this Mac · title will appear automatically"
        } catch {
            errorText = error.localizedDescription
            await capture?.stop(); capture = nil
            pumps.forEach { $0.cancel() }; pumps = []
            connections.values.forEach { $0.close() }; connections = [:]
            meeting?.status = "failed"; meeting?.endedAt = Date(); meeting?.failure = errorText
            try? save(); phase = "error"; message = errorText!
            await runtime.closeStreams(); library = store.list()
            if trigger != nil { autoPolicy.suppressCurrentCall() }
            runImports()
        }
    }
    func stop(userInitiated: Bool = true) async {
        guard phase == "recording" else { return }
        if userInitiated { autoPolicy.suppressCurrentCall() }
        phase = "finalizing"; meeting?.status = "finalizing"; message = "Finishing the transcript…"
        try? save()
        await capture?.stop(); capture = nil
        for pump in pumps { await pump.value }; pumps = []
        for connection in connections.values {
            do { try await connection.finish() } catch { errorText = error.localizedDescription }
            connection.close()
        }
        connections = [:]
        meeting?.endedAt = Date(); meeting?.status = errorText == nil ? "complete" : "interrupted"
        meeting?.failure = errorText
        if errorText == nil { meeting?.partials = [:]; meeting?.partialSpeakers = [:] }
        do { try save() } catch { errorText = "Unable to save transcript: \(error.localizedDescription)" }
        await runtime.closeStreams()
        phase = errorText == nil ? "ready" : "error"
        message = errorText ?? "Recording saved on this Mac"
        library = store.list()
        if let id = meeting?.id { scheduleTitle(id: id, final: true); analyzeVoices(id: id) }
        runImports()
    }
    private func fail(_ error: Error) async {
        errorText = error.localizedDescription
        if phase == "recording" { await stop() }
    }
    private func consume(_ event: [String: Any], source: String) {
        let kind = event["type"] as? String ?? ""
        if kind.hasSuffix(".partial") {
            meeting?.partials[source] = event["transcript"] as? String ?? ""
            if meeting?.partialSpeakers == nil { meeting?.partialSpeakers = [:] }
            meeting?.partialSpeakers?[source] = TranscriptParser.partialSpeaker(event: event, source: source)
        } else if kind.hasSuffix(".completed") {
            let segments = TranscriptParser.segments(event: event, source: source, offset: offsets[source] ?? 0, fallbackStart: ends[source] ?? 0)
            meeting?.segments.append(contentsOf: segments)
            if let last = segments.last { ends[source] = last.end }
            meeting?.partials.removeValue(forKey: source)
            meeting?.partialSpeakers?.removeValue(forKey: source)
        }
        do { try save() } catch { Task { await fail(error) } }
        if kind.hasSuffix(".completed"), let id = meeting?.id { scheduleTitle(id: id, final: false) }
    }
    func scheduleTitle(id: String, final: Bool) {
        guard let snapshot = meeting?.id == id ? meeting : try? store.load(id), TitlePolicy.canGenerate(snapshot, final: final) else { return }
        if titleJobs[id] != nil { if final { finalTitlesPending.insert(id) }; return }
        if !final && liveTitleAttempted.contains(id) { return }
        if !final { liveTitleAttempted.insert(id) }
        namingIDs.insert(id); titleError.removeValue(forKey: id)
        titleJobs[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                namingIDs.remove(id); titleJobs.removeValue(forKey: id)
                if finalTitlesPending.remove(id) != nil { scheduleTitle(id: id, final: true) }
            }
            do {
                let generated = try await titleGenerator.generate(transcript: TitlePolicy.excerpt(snapshot))
                guard var latest = meeting?.id == id ? meeting : try? store.load(id),
                      latest.titleOrigin == "pending" || latest.titleOrigin == "automatic" else { return }
                latest.title = generated; latest.titleOrigin = "automatic"; latest.titleFinal = final
                try store.save(latest)
                if meeting?.id == id { meeting = latest }
                library = store.list()
            } catch { titleError[id] = "Couldn’t generate a title. You can rename this recording." }
        }
    }
    func rename(id: String, to proposed: String) {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var latest = meeting?.id == id ? meeting : try? store.load(id) else { return }
        latest.title = String(name.prefix(120)); latest.titleOrigin = "manual"; latest.titleFinal = true
        do {
            try store.save(latest); if meeting?.id == id { meeting = latest }; library = store.list()
            titleError.removeValue(forKey: id)
        } catch { message = "Couldn’t save the title: \(error.localizedDescription)" }
    }
    func prepareToQuit() async {
        monitor?.cancel(); monitor = nil
        await pauseImports()
        await stop()
        while let job = titleJobs.values.first { await job.value }
        _ = try? await warmupTask?.value
        for task in voiceTasks.values { task.cancel() }
        await runtime.stop()
    }
    /// Deterministic, synthetic UI fixture. Never opens an audio device and is
    /// enabled only in the separately packaged QA app's environment.
    private func runCaptionDemo() async {
        meeting = Meeting(title: "Caption preview", titleOrigin: "pending")
        meeting?.recordingTrigger = "synthetic-preview"; selectedID = meeting?.id
        phase = "preview"; message = "Synthetic caption preview · no audio device is recording"
        let lines = [
            (1, "The cloud bill went up because staging workers were running overnight."),
            (2, "Let us turn off idle workers and add a monthly budget alert."),
            (1, "That should reduce staging costs without changing our production capacity."),
            (2, "I will set up the alert today and share the results tomorrow.")
        ]
        var timestamp = 0.0
        for (speaker, sentence) in lines {
            let words = sentence.split(separator: " ").map(String.init)
            for count in 1...words.count {
                if Task.isCancelled { return }
                consume(["type": "transcript.partial", "transcript": words.prefix(count).joined(separator: " ")], source: "system")
                try? await Task.sleep(nanoseconds: 180_000_000)
            }
            let labeled: [[String: Any]] = words.enumerated().map { index, word in
                ["word": word, "speaker": speaker, "start": timestamp + Double(index) * 0.18, "end": timestamp + Double(index + 1) * 0.18]
            }
            consume(["type": "transcript.completed", "transcript": sentence, "words": labeled], source: "system")
            timestamp += Double(words.count) * 0.18 + 0.2
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        meeting?.status = "complete"; meeting?.endedAt = Date(); try? save()
        phase = "ready"; message = "Synthetic preview complete"
        if let id = meeting?.id { scheduleTitle(id: id, final: true) }
    }
    private func save() throws { if let meeting { try store.save(meeting) } }
    func revealRecordings() { NSWorkspace.shared.open(store.root) }
    func copyMCPConfig() {
        let executable = Bundle.main.executableURL!.path
        let config: [String: Any] = ["mcpServers": ["workscribe": ["command": executable, "args": ["--mcp"]]]]
        let data = try! JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
        message = "MCP configuration copied. Add it to your LLM client."
    }
    func export() {
        guard let meeting = visibleMeeting else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "WorkScribe-transcript.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rows = meeting.orderedSegments.map { "[\(Self.timestamp($0.start))] \(meeting.speakerName(for: $0)): \($0.text)" }
        do { try ([meeting.title, ""] + rows).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8) }
        catch { message = error.localizedDescription }
    }
    static func timestamp(_ seconds: Double) -> String {
        let value = max(0, Int(seconds)); return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
