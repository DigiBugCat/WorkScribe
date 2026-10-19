import AppKit
import Foundation
import WorkScribeCore
#if WORKSCRIBE_PLAUD
import WorkScribePlaud
#endif

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
    /// Where the transcript comes from: "recorder" (this Mac's audio), "zoom-captions"
    /// (Zoom's own live captions, read through Accessibility; nothing is recorded), or
    /// "auto" (Zoom's captions when a Zoom meeting is showing them, otherwise this Mac's audio).
    @Published var transcriptSource = UserDefaults.standard.string(forKey: "transcriptSource") ?? "recorder" {
        didSet { UserDefaults.standard.set(transcriptSource, forKey: "transcriptSource") }
    }
    private var captionTask: Task<Void, Never>?
    private var captions = CaptionStream()
    var readingCaptions: Bool { captionTask != nil }
    @Published var includeSystemAudio = UserDefaults.standard.object(forKey: "includeSystemAudio") as? Bool ?? true {
        didSet { UserDefaults.standard.set(includeSystemAudio, forKey: "includeSystemAudio") }
    }
    /// Whether macOS currently allows system-audio capture (Screen Recording).
    @Published var screenAccess = CGPreflightScreenCaptureAccess()
    /// The current recording fell back to microphone only.
    @Published var systemAudioBlocked = false
    /// The current recording's microphone problem, in plain words; nil while the mic works.
    @Published var microphoneIssue: String?
    /// Apple voice processing is cancelling speaker echo on the mic for this recording.
    @Published var echoCancelling = false
    @Published var globalShortcut = UserDefaults.standard.object(forKey: "globalShortcut") as? Bool ?? true {
        didSet { UserDefaults.standard.set(globalShortcut, forKey: "globalShortcut") }
    }
    @Published var speakerToast: SpeakerToast?
    // Screen awareness (AppModel+Screen.swift). Opt-in; on by default only when Screen Recording is already allowed.
    @Published var screenCaptureEnabled = UserDefaults.standard.object(forKey: "screenCaptureEnabled") as? Bool ?? CGPreflightScreenCaptureAccess() {
        didSet { UserDefaults.standard.set(screenCaptureEnabled, forKey: "screenCaptureEnabled") }
    }
    /// "Pause screen capture" during a recording: nothing is written, read or indexed until resumed. Resets per recording.
    @Published var screenCapturePaused = false { didSet { screenRecorder?.setPaused(screenCapturePaused) } }
    @Published var screenCaptureTarget = ScreenCaptureTarget(rawValue: UserDefaults.standard.string(forKey: "screenCaptureTarget") ?? "") ?? .display {
        didSet { UserDefaults.standard.set(screenCaptureTarget.rawValue, forKey: "screenCaptureTarget") }
    }
    @Published var screenState: ScreenCaptureState = .off
    /// The current recording's screen moments so far.
    @Published var screenMoments: [ScreenMoment] = []
    @Published var finalizationProgress: Double = 0
    var screenRecorder: ScreenRecorder?
    /// The bundle ID of the call that triggered the current automatic recording (window-mode capture target).
    var callBundleID: String?
    /// Called after a meeting's files change outside recording (a screen recording deleted), to refresh search.
    var onLibraryChanged: (() -> Void)?
    var retentionService: MeetingRetention?
    let levels = LevelMonitor()
    private var tracks: [String: AudioTrack] = [:]
    private var voiceWindows: [String: VoiceAudioWindow] = [:]
    var liveVoiceTasks: [String: Task<Void, Never>] = [:]
    private var levelTask: Task<Void, Never>?
    @Published var selectedID: String?
    /// The moment a `workscribe://` link or a citation asked to show; transcripts scroll to it and highlight it.
    @Published var focusRequest: TranscriptFocus?
    @Published var speechReady = false
    @Published var speechStatus = "Warming speech engine…"
    let store: MeetingStore
    var lineIndex: SearchIndex?
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
    @Published var recordingPressure: RecordingPressure = .normal { didSet { ScreenInferenceAdmission.shared.set(recordingPressure) } }
    var liveAIPaused: Bool { recordingPressure >= .aiPaused }
    private var capture: (any AudioCapturing)?
    /// The Mac's audio devices; `--replay --audio` replays a recording's files instead.
    var makeCapture: () -> any AudioCapturing = { AudioCapture() }
    /// Tests only: the recognition lag, in place of the tracks' backlogs.
    var lagProbe: (() -> Double)?
    /// Verification only: extra time per second of audio before recognition, to simulate a busy Mac.
    var recognitionDelay: (() -> UInt64)?
    private(set) var recordingGeneration = UUID()
    private var stopTask: Task<Void, Never>?
    // Injectable only to bound stalled work; ordinary backlog may drain as long as it progresses.
    var stallTimeout: TimeInterval = 30

    var makeConnection: (() -> any SpeechStreaming)?
    private var connections: [String: any SpeechStreaming] = [:]
    private var pumps: [Task<Void, Never>] = []
    private var offsets: [String: Double] = [:]
    private var errorText: String?
    private var recognizerStalled = false
    private let titleGenerator: any TitleGenerating
    private var liveTitleAttempted: Set<String> = []
    private var titleJobs: [String: Task<Void, Never>] = [:]
    private var finalTitlesPending: Set<String> = []
    private let callDetector = CallDetector()
    private var autoPolicy = AutoRecordPolicy()
    private var monitor: Task<Void, Never>?
    private var warmupTask: Task<Void, Error>?
    // Note Pro recordings waiting to be transcribed into the library (PlaudImport.swift).
    #if WORKSCRIBE_PLAUD
    @Published var importQueue: [PlaudSavedRecording] = []
    #endif
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
        do { try store.recoverInterruptedRecordings() }
        catch { phase = "error"; message = "Couldn’t recover the last recording: \(error.localizedDescription)" }
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
        let access = CGPreflightScreenCaptureAccess()
        if access != screenAccess { screenAccess = access }
        guard autoRecordCalls else { autoStatus = "Automatic recording off"; return }
        // Zoom's captions need no speech engine, so a captions meeting can start before it is warm.
        guard speechReady || transcriptSource != "recorder" else { return }
        let snapshot = callDetector.snapshot()
        guard snapshot.available else { autoStatus = "Call detection unavailable; use Start recording"; return }
        autoStatus = snapshot.signal.map { "Call activity: \($0.name)" }
            ?? (snapshot.browserPermission ? "Watching for calls" : "Watching call apps · browser detection needs Screen Recording access")
        let automatic = phase == "recording" && meeting?.recordingTrigger?.hasPrefix("call:") == true
        switch autoPolicy.update(callActive: snapshot.signal != nil, enabled: true, busy: busy,
                                automaticallyRecording: automatic, now: Date()) {
        case .start:
            if let signal = snapshot.signal { callBundleID = signal.bundleID; Task { await start(trigger: signal.name) } }
        case .stop: Task { await stop(userInitiated: false) }
        case .none: break
        }
    }
    func prepareSpeech() async throws {
        guard !recognizerStalled else { throw CaptureError.message("The speech engine stopped responding. Restart WorkScribe to record again. Your transcript is saved.") }
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
    func start(trigger: String? = nil, resuming id: String? = nil, source: String? = nil) async {
        guard !busy || (phase == "finalizing" && finalizationProgress >= 0.35 && id == meeting?.id && meeting?.canResume() == true) else { return }
        // A call that a restart or crash cut off carries on in the same meeting and note. A meeting that
        // ended normally is never picked up again, so back-to-back calls stay separate.
        var id = id
        if id == nil, let trigger, let cut = library.first(where: { $0.recordingTrigger == "call:\(trigger)" && $0.status == "interrupted" && $0.canResume() }) {
            id = cut.id
        }
        let chosen = source ?? transcriptSource
        var captionsChosen = chosen == "zoom-captions"
        if chosen == "auto", ZoomCaptions.trusted { captionsChosen = await ZoomCaptions.read().inMeeting }
        if captionsChosen, id == nil || meetingSnapshot(id!)?.transcriptSource == "zoom-captions" {
            await startCaptions(trigger: trigger, resuming: id); return
        }
        var resumed: Meeting?
        if let id {
            guard var existing = meetingSnapshot(id), existing.canResume() else {
                errorText = "Resume is available for ten minutes after stopping, before finalizing."; return
            }
            do { try existing.resume(); resumed = existing } catch { return }
        }
        NoteEnhancementScheduler.shared.cancelSynthesis()
        finalizationProgress = 0
        phase = "starting"; message = "Starting recording…"; errorText = nil
        liveVoiceTasks.values.forEach { $0.cancel() }; liveVoiceTasks = [:]
        offsets = [:]; recordingGeneration = UUID(); recordingPressure = .normal; liveTranscript = LiveTranscript()
        await pauseImports()
        do {
            try await prepareSpeech()
            meeting = resumed ?? Meeting(title: "Recording · \(Date().formatted(date: .abbreviated, time: .shortened))", titleOrigin: "pending")
            if meeting?.recordingSessions == nil { meeting?.recordingSessions = [RecordingSession(id: "initial", start: 0)] }
            meeting?.recordingTrigger = trigger.map { "call:\($0)" } ?? "manual"
            selectedID = meeting?.id
            try save()
            let session = meeting!.recordingSessions!.last!
            let mic = AudioTrack()
            let system = includeSystemAudio ? AudioTrack() : nil
            voiceWindows = [:]
            systemAudioBlocked = false; microphoneIssue = nil; echoCancelling = false
            tracks = ["microphone": mic]; if let system { tracks["system"] = system }
            for (source, track) in [("microphone", mic), ("system", system)].compactMap({ source, track in track.map { (source, $0) } }) {
                let connection = makeConnection?() ?? SpeechConnection(runtime: runtime)
                let generation = recordingGeneration
                connection.onEvent = { [weak self] event in
                    guard let self, self.recordingGeneration == generation else { return }
                    self.consume(event, source: source)
                }
                track.onFailure = { [weak self] error in Task { @MainActor in await self?.fail(error) } }
                connections[source] = connection
                try await connection.connect()
                pumps.append(Task { [weak self] in
                    do {
                        while let data = try await track.backlog.next() {
                            guard let self else { return }
                            if offsets[source] == nil {
                                offsets[source] = (track.firstCaptureAt ?? Date()).timeIntervalSince(meeting!.startedAt)
                                if meeting?.sourceOffsets == nil { meeting?.sourceOffsets = [:] }
                                if session.id == "initial" { meeting?.sourceOffsets?[source] = offsets[source] }
                                if let index = meeting?.recordingSessions?.indices.last { meeting?.recordingSessions?[index].sourceOffsets[source] = offsets[source] }
                            }
                            if let delay = self.recordingDelayNanoseconds(), delay > 0 { try await Task.sleep(nanoseconds: delay) }
                            voiceWindows[source, default: VoiceAudioWindow()].append(data)
                            try await connection.write(data)
                            track.backlog.acknowledge(data.count)
                            self.updateRecordingPressure()
                        }
                    } catch {
                        guard let self, recordingGeneration == generation, !Task.isCancelled else { return }
                        // There is no disk fallback. Stop capture and preserve the text received.
                        Task { await self.fail(error) }
                    }
                })
            }
            let capture = makeCapture(); self.capture = capture
            capture.onFailure = { [weak self] error in Task { @MainActor in await self?.fail(error) } }
            capture.onChange = { [weak self] in Task { @MainActor in self?.captureChanged() } }
            message = "Waiting for audio permissions…"
            try await capture.start(microphone: mic, system: system)
            if let errorText { throw CaptureError.message(errorText) }
            if capture.systemAudioError != nil {
                // Keep the microphone recording; drop the system track that never started.
                systemAudioBlocked = true; screenAccess = false
                connections.removeValue(forKey: "system")?.close(); tracks.removeValue(forKey: "system")
            }
            if capture.microphoneError != nil {
                // Keep the call audio recording; drop the microphone track that never opened.
                dropMicrophone()
            }
            echoCancelling = capture.echoCancelling
            await startScreen()
            phase = "recording"
            message = microphoneIssue ?? trigger.map { "Automatically recording \($0) · saved on this Mac" } ?? "Recording on this Mac · title will appear automatically"
            startLevels()
            // The relevance check for notes matched by typing time needs EmbeddingGemma; load it now,
            // not when the first note is waiting.
            Enrich.warmEmbedder()
            let recordingID = meeting?.id
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, phase == "recording", meeting?.id == recordingID else { return }
                // Exact digital zero from an open mic is a muted or misrouted input, never a quiet room.
                if microphoneIssue == nil, let track = tracks["microphone"], track.isDigitallySilent || !track.hasSamples {
                    let health = CaptureHealth(microphone: .silent(device: capture.microphoneDevice), systemRequested: includeSystemAudio,
                                               systemWorking: tracks["system"] != nil)
                    microphoneIssue = health.degradedMessage
                    if let issue = microphoneIssue { message = issue; Notifier.post("Your mic is sending only silence", issue) }
                }
                let hasSystem = (meeting?.orderedSegments ?? []).contains { $0.source == "system" }
                if systemAudioBlocked || (!hasSystem && includeSystemAudio && (levels.system ?? 0) < 0.001) {
                    let names = (meeting?.attendees ?? []).filter { $0 != "You" }.map { $0.components(separatedBy: " ").first ?? $0 }
                    let people = names.isEmpty ? "Other people on this call" : names.joined(separator: " and ")
                    message = people + " won’t be in the transcript. Check system audio."
                    Notifier.post("Only your microphone is coming through", message)
                }
            }
            if let trigger {
                if UserDefaults.standard.object(forKey: "automaticStartTick") as? Bool != false { NSSound(named: "Tink")?.play() }
                Notifier.post("Recording your \(trigger) call",
                              systemAudioBlocked ? "Microphone only: allow Screen Recording to capture the other side."
                                : microphoneIssue ?? "Transcribing on this Mac. Click the menu bar icon to follow along.")
            }
        } catch {
            errorText = error.localizedDescription
            await stopScreen()
            await capture?.stop(); capture = nil
            pumps.forEach { $0.cancel() }; pumps = []
            tracks.values.forEach { $0.finish(); $0.backlog.discard() }; tracks = [:]; voiceWindows = [:]
            connections.values.forEach { $0.close() }; connections = [:]
            meeting?.status = "failed"; meeting?.endedAt = Date(); meeting?.failure = errorText
            try? save(); phase = "error"; message = errorText!
            await runtime.closeStreams(); library = store.list()
            if let trigger {
                autoPolicy.suppressCurrentCall()
                Notifier.post("Couldn’t record your \(trigger) call", FailureCallout.explain(errorText ?? "").title + ". Open WorkScribe to fix it.")
            }
            stopLevels()
            runImports()
        }
    }
    /// Takes the transcript from Zoom's live captions instead of this Mac's audio. No microphone,
    /// no system audio and no speech model: Zoom has already turned speech into text.
    private func startCaptions(trigger: String?, resuming id: String? = nil) async {
        finalizationProgress = 0; errorText = nil
        guard ZoomCaptions.requestAccess() else {
            phase = "error"; message = "WorkScribe needs Accessibility access to read Zoom’s captions. Allow it in System Settings › Privacy & Security › Accessibility."
            return
        }
        guard await ZoomCaptions.read().inMeeting else { phase = "error"; message = "Zoom isn’t in a meeting."; return }
        NoteEnhancementScheduler.shared.cancelSynthesis()
        await pauseImports()
        recordingGeneration = UUID(); recordingPressure = .normal; liveTranscript = LiveTranscript()
        offsets = ["captions": 0]; captions = CaptionStream()
        var fresh: Meeting
        if let id, var existing = meetingSnapshot(id), existing.canResume(), (try? existing.resume()) != nil {
            fresh = existing
            let at = Date().timeIntervalSince(existing.startedAt)
            captions.prime(with: existing.orderedSegments.suffix(80).map(\.text).joined(separator: " "), at: at)
        } else {
            fresh = Meeting(title: "Zoom meeting · \(Date().formatted(date: .abbreviated, time: .shortened))", titleOrigin: "pending")
            fresh.recordingSessions = [RecordingSession(id: "initial", start: 0)]
        }
        fresh.recordingTrigger = trigger.map { "call:\($0)" } ?? fresh.recordingTrigger ?? "manual"
        fresh.transcriptSource = "zoom-captions"
        meeting = fresh; selectedID = fresh.id
        do { try save() } catch { phase = "error"; message = "Couldn’t save the meeting: \(error.localizedDescription)"; return }
        phase = "recording"; message = "Reading Zoom’s captions · nothing is recorded"
        Enrich.warmEmbedder()
        let generation = recordingGeneration, started = fresh.startedAt
        let trace: FileHandle? = UserDefaults.standard.string(forKey: "captionTrace").flatMap { path in
            FileManager.default.createFile(atPath: path, contents: nil); return FileHandle(forWritingAtPath: path)
        }
        captionTask = Task { [weak self] in
            var captionsSeen = Date()
            while !Task.isCancelled {
                guard let self, recordingGeneration == generation else { return }
                let at = Date().timeIntervalSince(started)
                let reading = await ZoomCaptions.read(at: at, trace: trace != nil)
                guard recordingGeneration == generation, !Task.isCancelled else { break }
                if let row = reading.trace { trace?.write(row) }
                let events = captions.observe(reading.looks ?? [], at: at)
                if !events.isEmpty { applyCaptions(events) }
                if reading.captionsOn || !events.isEmpty { captionsSeen = Date() }
                if reading.needsScreenAccess { message = "Allow Screen Recording so WorkScribe can read Zoom’s captions while you share" }
                else if !reading.inMeeting { message = "Zoom’s meeting window closed · stop when you’re done" }
                else if Date().timeIntervalSince(captionsSeen) > 8 { message = "Turn on captions in Zoom (More › Show captions) so WorkScribe can follow along" }
                else if ["Turn on captions in Zoom", "Zoom’s meeting window", "Allow Screen Recording so"].contains(where: message.hasPrefix) {
                    message = "Reading Zoom’s captions · nothing is recorded"
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            try? trace?.close()
        }
    }
    private func applyCaptions(_ events: [[String: Any]]) {
        for event in events { consume(event, source: "captions") }
        guard var current = meeting else { return }
        for (index, name) in captions.names.enumerated() where current.speakerAssignments?["captions:speaker-\(index + 1)"] == nil {
            if current.speakerAssignments == nil { current.speakerAssignments = [:] }
            current.speakerAssignments?["captions:speaker-\(index + 1)"] = SpeakerAssignment(name: name)
        }
        if current.speakerAssignments != meeting?.speakerAssignments { meeting = current; try? save() }
    }
    func stop(userInitiated: Bool = true) async {
        if let stopTask { await stopTask.value; return }
        guard phase == "recording" else { return }
        let task = Task { await self.finishRecording(userInitiated: userInitiated) }
        stopTask = task
        await task.value
        stopTask = nil
    }
    private func finishRecording(userInitiated: Bool) async {
        if userInitiated { autoPolicy.suppressCurrentCall() }
        finalizationProgress = 0.1
        phase = "finalizing"; meeting?.status = "finalizing"; message = "Finishing the transcript…"
        meeting?.endedAt = Date()
        // Finish the current short line while admitting no new live work during ASR drain.
        if let id = meeting?.id { NoteEnhancementScheduler.shared.beginStop(id) }
        try? save()
        if let task = captionTask {
            task.cancel(); captionTask = nil
            if let started = meeting?.startedAt { applyCaptions(captions.flush(at: Date().timeIntervalSince(started))) }
        }
        let stoppingCapture = capture; capture = nil
        stoppingCapture?.onFailure = nil
        try? await RecordingDeadline.wait(stall: stallTimeout) { await stoppingCapture?.stop() }
        // Screen/OCR is optional and cannot hold transcript finalization hostage.
        try? await RecordingDeadline.wait(stall: stallTimeout) { await self.stopScreen() }
        stopLevels()
        let draining = pumps
        let finishing = Array(connections.values)
        let progress = Array(tracks.values).map(\.backlog)
        do {
            try await RecordingDeadline.wait(stall: stallTimeout, progress: { progress.reduce(0) { $0 + $1.pendingSeconds } }) {
                for pump in draining { await pump.value }
                for connection in finishing { try await connection.finish() }
            }
        } catch {
            errorText = "The transcript could not finish. Your transcript is saved. Restart WorkScribe before recording again."
            recognizerStalled = true; speechReady = false
            recordingGeneration = UUID() // Fence any late recognition callbacks.
            draining.forEach { $0.cancel() }
        }
        if errorText == nil {
            for source in liveTranscript.unfinishedSources {
                consume(["type": "transcript.completed", "transcript": ""], source: source)
            }
        }
        pumps = []
        finishing.forEach { $0.close() }
        tracks.values.forEach { $0.backlog.discard() }
        tracks = [:]; voiceWindows = [:]

        connections = [:]
        if let index = meeting?.recordingSessions?.indices.last, let ended = meeting?.endedAt, let started = meeting?.startedAt {
            meeting?.recordingSessions?[index].end = ended.timeIntervalSince(started)
        }
        // Settle the same text-only echo filter after both live streams have drained.
        meeting?.removeEchoes()
        meeting?.status = errorText == nil ? "complete" : "interrupted"
        meeting?.failure = errorText
        if errorText == nil { meeting?.partials = [:]; meeting?.partialSpeakers = [:] }
        do { try save() } catch { errorText = "Unable to save transcript: \(error.localizedDescription)" }
        // Connections close on the inference queue without blocking saved-state recovery.
        finalizationProgress = 0.35
        var finalPassWarning: String?
        let stoppedAt = meeting?.endedAt
        let stoppedGeneration = recordingGeneration
        if let id = meeting?.id {
            let finished = await NoteEnhancementScheduler.shared.finish(id, model: self)
            if let reason = NoteEnhancementScheduler.shared.warnings[id] {
                finalPassWarning = (finished ? "Recording saved · " : "Recording saved · no final notes: ") + reason
            } else if !finished { finalPassWarning = "Recording saved · the final AI pass could not finish" }
            // Resumed during the final pass: the new session owns the meeting now.
            guard recordingGeneration == stoppedGeneration, meeting?.id == id, meeting?.endedAt == stoppedAt else { return }
            finalizationProgress = 0.9
            do {
                if meeting?.document == nil {
                    try await RecordingDeadline.wait(stall: stallTimeout) { try await self.retentionService?.finalize(id) }
                }
                else {
                    try mutateMeeting(id) { $0.retention = "live"; $0.purgeAt = $0.endedAt?.addingTimeInterval(86_400) }
                    let receipts = RetentionStore(meetings: store)
                    if var receipt = try receipts.load(id), let latest = meetingSnapshot(id), let end = latest.endedAt {
                        receipt.endedAt = end; receipt.purgeAt = end.addingTimeInterval(86_400); try receipts.save(receipt)
                    }
                }
            }
            catch { errorText = "Couldn’t finalize notes: \(error.localizedDescription)" }
        }
        finalizationProgress = 1
        recordingPressure = .normal
        phase = errorText == nil ? "ready" : "error"
        message = errorText ?? finalPassWarning ?? "Recording saved on this Mac"
        library = store.list()
        if let id = meeting?.id { scheduleTitle(id: id, final: true); analyzeVoices(id: id) }
        if !userInitiated, meeting?.recordingTrigger?.hasPrefix("call:") == true {
            Notifier.post(errorText == nil ? "Call recording saved" : "Call recording stopped early",
                          errorText == nil ? "The transcript is in WorkScribe’s Recent list." : FailureCallout.explain(errorText ?? "").title)
        }
        runImports()
    }
    /// The microphone could not open, or stopped mid-call: the call audio carries on alone.
    private func dropMicrophone() {
        let health = CaptureHealth(microphone: .unavailable(capture?.microphoneError?.localizedDescription ?? ""),
                                   systemRequested: includeSystemAudio, systemWorking: tracks["system"] != nil)
        microphoneIssue = health.degradedMessage
        // An unopened mic has no clock and no samples; an opened one keeps what it recorded.
        if offsets["microphone"] == nil {
            connections.removeValue(forKey: "microphone")?.close(); tracks.removeValue(forKey: "microphone")
        }
    }
    /// A source changed while recording (a headset route change, the call audio stopping).
    private func captureChanged() {
        guard phase == "recording", let capture else { return }
        echoCancelling = capture.echoCancelling
        if capture.microphoneError != nil, microphoneIssue == nil {
            dropMicrophone()
            if let microphoneIssue { message = microphoneIssue; Notifier.post("Your mic stopped", microphoneIssue) }
        } else if capture.microphoneError == nil, microphoneIssue != nil, tracks["microphone"] != nil {
            microphoneIssue = nil; message = "Recording on this Mac · your mic is back"
        }
        if capture.systemAudioError != nil, !systemAudioBlocked {
            systemAudioBlocked = true
            message = "Recording your mic only · the call audio stopped"
        }
    }
    private func recordingDelayNanoseconds() -> UInt64? { recognitionDelay?() }
    private func fail(_ error: Error) async {
        guard phase == "recording" || phase == "starting" else { return }
        errorText = error.localizedDescription
        if phase == "recording" { await stop() }
    }
    private var liveTranscript = LiveTranscript()
    func consume(_ event: [String: Any], source: String) {
        let kind = event["type"] as? String ?? ""
        let namespace = meeting?.recordingSessions?.last?.id
        func speaker(_ value: String) -> String { namespace == nil || namespace == "initial" ? value : namespace! + ":" + value }
        guard var current = meeting else { return }
        let count = current.segments.count
        guard liveTranscript.consume(event, source: source, offset: offsets[source] ?? 0,
                                     pressure: recordingPressure, meeting: &current) else { return }
        for i in count..<current.segments.count { current.segments[i].speaker = speaker(current.segments[i].speaker) }
        if let key = current.partialSpeakers?[source] { current.partialSpeakers?[source] = speaker(key) }
        // The call heard again through the speakers is not the user talking.
        if kind.hasSuffix(".completed") { current.removeEchoes() }
        meeting = current
        if kind.hasSuffix(".completed") { captureVoiceEmbeddings(source: source) }
        do { try save() } catch {
            message = "Transcript could not be saved"
        }
        if kind.hasSuffix(".completed"), let id = meeting?.id {
            scheduleTitle(id: id, final: false)
            if phase == "recording" { NoteEnhancementScheduler.shared.schedule(id, model: self) }
        }
    }
    /// Crop while the recognizer's single-speaker span is still in the rolling window.
    /// Keep only derived vectors for later naming; at most one crop per source in flight.
    private func captureVoiceEmbeddings(source: String) {
        guard liveVoiceTasks[source] == nil, let snapshot = meeting,
              let window = voiceWindows[source], let offset = offsets[source] else { return }
        let existing = snapshot.voiceEmbeddings ?? [:]
        guard let turn = TranscriptTurns.group(snapshot, segments: snapshot.orderedSegments.filter { $0.source == source }).reversed().first(where: { turn in
            guard let last = turn.segments.last else { return false }
            return last.source == source && existing[last.id] == nil && turn.end - turn.first.start >= 3
                && snapshot.segments.filter { $0.speaker == last.speaker && existing[$0.id] != nil }.count < 3
        }), let segment = turn.segments.last else { return }
        var span = segment; span.start = turn.first.start; span.end = turn.end
        guard VoiceMatching.eligible(span, in: snapshot),
              let samples = window.samples(start: max(0, span.end - offset - min(10, span.end - span.start)),
                                           duration: min(10, span.end - span.start)) else { return }
        let generation = recordingGeneration
        liveVoiceTasks[source] = Task { [weak self] in
            guard let self else { return }
            defer { if recordingGeneration == generation { liveVoiceTasks[source] = nil } }
            do {
                let vector = try await voiceEngine.embedding(samples: samples)
                guard !Task.isCancelled, recordingGeneration == generation, meeting?.id == snapshot.id,
                      meeting?.segments.contains(where: { $0.id == segment.id }) == true else { return }
                try mutateMeeting(snapshot.id) { current in
                    if current.voiceEmbeddings == nil { current.voiceEmbeddings = [:] }
                    current.voiceEmbeddings?[segment.id] = vector
                }
                analyzeVoices(id: snapshot.id)
            } catch { /* Optional voice matching never blocks transcription. */ }
        }
    }
    func scheduleTitle(id: String, final: Bool) {
        guard let snapshot = meeting?.id == id ? meeting : try? store.load(id), TitlePolicy.canGenerate(snapshot, final: final) else { return }
        if titleJobs[id] != nil { if final { finalTitlesPending.insert(id) }; return }
        if !final && liveAIPaused { return }
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
                guard !Task.isCancelled, var latest = meeting?.id == id ? meeting : try? store.load(id),
                      latest.retention != "purged", latest.retention != "purging", latest.titleOrigin == "pending" || latest.titleOrigin == "automatic" else { return }
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
        let jobs = Array(titleJobs.values)
        try? await RecordingDeadline.wait(stall: stallTimeout) { for job in jobs { await job.value } }
        titleJobs.values.forEach { $0.cancel() }
        // A stalled optional model must never strand macOS in terminateLater.
        warmupTask?.cancel()
        for task in voiceTasks.values { task.cancel() }
        Task { await runtime.stop() }
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
    func save() throws { if let meeting { try store.save(meeting) } }
    private func startLevels() {
        levelTask?.cancel()
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                updateRecordingPressure()
                levels.update(microphone: tracks["microphone"]?.currentLevel() ?? 0, system: tracks["system"]?.currentLevel())
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
    /// Seconds of captured audio not yet through recognition, per source.
    var transcriptLag: [String: Double] { tracks.mapValues { $0.backlog.pendingSeconds } }
    func updateRecordingPressure() {
        guard phase == "recording" else { return }
        let lag = lagProbe?() ?? tracks.values.map { $0.backlog.pendingSeconds }.max() ?? 0
        let next = errorText == nil ? RecordingPressure(lag: lag) : .transcriptDelayed
        guard recordingPressure != next else { return }
        let wasPaused = liveAIPaused
        recordingPressure = next
        screenRecorder?.setPressure(next)
        message = next == .normal ? "Recording on this Mac · transcript caught up" : next.message
        // AI lines resume the moment they are allowed again, not only at full recovery: under a
        // steady load the lag can settle between 2 and 6 s, and after the call goes quiet no new
        // transcript event would ever schedule the notes that waited.
        if wasPaused, !liveAIPaused, let id = meeting?.id { NoteEnhancementScheduler.shared.schedule(id, model: self) }
        // Falling behind: the transcript comes first, so a live pass in flight yields the GPU.
        if !wasPaused, liveAIPaused, let id = meeting?.id { NoteEnhancementScheduler.shared.yieldLive(id) }
    }
    private func stopLevels() { levelTask?.cancel(); levelTask = nil; levels.reset() }
    /// Moves a recording's folder to the Trash, so a mistaken delete can be recovered in Finder.
    func deleteRecording(id: String) {
        guard !(busy && meeting?.id == id) else { return }
        do {
            try invalidateVoices(id: id)
            try FileManager.default.trashItem(at: store.directory(id), resultingItemURL: nil)
            if selectedID == id { selectedID = nil }
            if meeting?.id == id { meeting = nil }
            speakerUndo.removeValue(forKey: id)
            library = store.list(); message = "Recording moved to the Trash"
        } catch { message = "Couldn’t move the recording to the Trash: \(error.localizedDescription)" }
    }
    func requestScreenAccess() {
        screenAccess = CGRequestScreenCaptureAccess()
        if !screenAccess, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
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
