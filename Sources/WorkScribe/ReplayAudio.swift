import AVFoundation
import Foundation
import WorkScribeCore

/// Plays a recording's WAVs into `AudioTrack`s at the pace they were captured, in place of the Mac's
/// devices. Everything after the tracks is the app's own: backlog, recognizer, reducer, echo filter.
final class FileCapture: AudioCapturing {
    var onFailure: ((Error) -> Void)?
    var onChange: (() -> Void)?
    private(set) var systemAudioError: Error?
    private(set) var microphoneError: Error?
    var echoCancelling: Bool { false }
    var microphoneDevice: String? { "Replayed microphone.wav" }
    let system: URL, microphone: URL
    /// How much later than system audio the microphone started (the recording's offset difference).
    let microphoneDelay: Double
    let pace: Double
    private var tasks: [Task<Void, Never>] = []
    private(set) var finished = false
    init(system: URL, microphone: URL, microphoneDelay: Double, pace: Double) {
        self.system = system; self.microphone = microphone; self.microphoneDelay = microphoneDelay; self.pace = pace
    }
    func start(microphone track: AudioTrack, system systemTrack: AudioTrack?) async throws {
        tracks = [track] + (systemTrack.map { [$0] } ?? [])
        var feeds: [(URL, AudioTrack, Double)] = [(microphone, track, max(0, microphoneDelay))]
        if let systemTrack { feeds.append((system, systemTrack, max(0, -microphoneDelay))) }
        let pace = self.pace
        for (url, target, delay) in feeds {
            let file = try AVAudioFile(forReading: url)
            tasks.append(Task.detached(priority: .userInitiated) { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay / pace * 1e9))
                let started = Date(), rate = file.processingFormat.sampleRate
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(rate / 10))!
                while file.framePosition < file.length, !Task.isCancelled {
                    do { try file.read(into: buffer) } catch { break }
                    target.accept(buffer)
                    // Real time: never run ahead of the wall clock.
                    let due = Double(file.framePosition) / rate / pace - Date().timeIntervalSince(started)
                    if due > 0 { try? await Task.sleep(nanoseconds: UInt64(due * 1e9)) }
                }
                if file.framePosition >= file.length { self?.finished = true }
            })
        }
    }
    private var tracks: [AudioTrack] = []
    func stop() async {
        tasks.forEach { $0.cancel() }; tasks = []
        // Like AudioCapture: closing the tracks is what lets the recognizer drain and finish.
        tracks.forEach { $0.finish() }; tracks = []
    }
}

/// The live sequence end to end without audio hardware: start through the local API, open the
/// meeting note, type the notes into it on their original schedule, slow recognition down for a
/// stretch (a busy Mac), Stop through the API, then check what the person would see.
@MainActor enum ReplayAudio {
    static func run(fixture: URL, output: URL, duration: Double) async throws {
        let pace = 1.0
        let until: Double? = duration
        let root = output.appendingPathComponent("audio-state-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // Isolated from the person's settings: argument-domain values are never written to disk.
        UserDefaults.standard.setVolatileDomain(["screenCaptureEnabled": false, "includeSystemAudio": true, "autoRecordCalls": false],
                                                forName: UserDefaults.argumentDomain)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let source = try decoder.decode(Meeting.self, from: Data(contentsOf: fixture.appendingPathComponent("transcript.json")))
        let notes = (source.notes ?? []).compactMap { note in note.createdAt.map { (text: note.text, at: $0) } }.sorted { $0.at < $1.at }
        let offsets = source.recordingSessions?.first?.sourceOffsets ?? source.sourceOffsets ?? [:]
        let micDelay = (offsets["microphone"] ?? offsets["system"] ?? 0) - (offsets["system"] ?? 0)
        let systemURL = fixture.appendingPathComponent("system.wav"), micURL = fixture.appendingPathComponent("microphone.wav")
        let length = min(until ?? .greatestFiniteMagnitude, try AVAudioFile(forReading: systemURL).duration)

        func capturedMedia(in folder: URL) -> Set<String> {
            let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
            return Set((files?.compactMap { $0 as? URL } ?? []).filter {
                ["wav", "pcm", "m4a", "mp3", "caf", "aiff", "mov", "mp4", "jpg", "png"].contains($0.pathExtension.lowercased())
            }.map(\.path))
        }
        let cacheRoots = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/WorkScribe")]
            + (ProcessInfo.processInfo.environment["WORKSCRIBE_RUNTIME_CACHE"].map { [URL(fileURLWithPath: $0)] } ?? [])
        let cacheMediaBefore = cacheRoots.reduce(into: Set<String>()) { $0.formUnion(capturedMedia(in: $1)) }
        let store = MeetingStore(root: root.appendingPathComponent("Meetings"))
        let model = AppModel(store: store)
        let capture = FileCapture(system: systemURL, microphone: micURL, microphoneDelay: micDelay, pace: pace)
        model.makeCapture = { capture }
        let clock = Date()
        func elapsed() -> Double { Date().timeIntervalSince(clock) * pace }
        let ask = AskService(model: model, store: ConversationStore(root: root.appendingPathComponent("Conversations")), generator: nil)
        let vault = VaultStore(root: root.appendingPathComponent("Vault"), stateDirectory: root.appendingPathComponent("State"))
        model.retentionService = MeetingRetention(model: model, ask: ask, vault: vault, index: nil, requiresIndex: false)
        // Opt-in paired experiment; all index files are under this replay's disposable root.
        let indexing = true
        let oldEmbedder = Enrich.embedderSource
        defer { Enrich.embedderSource = oldEmbedder }
        let generator = ReplayAudioModel(wrapped: try GemmaEvaluation.model(runtime: "llama"))
        let oldEnhancer = NoteEnhancementScheduler.shared.enhancer
        NoteEnhancementScheduler.shared.enhancer = Enrich(textModel: generator)
        defer { NoteEnhancementScheduler.shared.enhancer = oldEnhancer }
        var indexService: IndexService?, indexHookup: SearchHookup?
        if indexing {
            let searchIndex = try SearchIndex(url: root.appendingPathComponent("Index/index.sqlite"))
            let service = IndexService(index: searchIndex, store: store, embedder: CoreMLEmbedder.bundled())
            indexService = service
            indexHookup = SearchHookup(model: model, service: service)
            Enrich.embedderSource = { await service.queryEmbedder }
            NoteEnhancementScheduler.shared.enhancer = Enrich(textModel: generator, indexSource: { await service.evidenceIndex() })
            ask.index = service
            if let i = CommandLine.arguments.firstIndex(of: "--index-backlog"), i + 1 < CommandLine.arguments.count {
                let backlog = FileIdentity.url(URL(fileURLWithPath: CommandLine.arguments[i + 1]))
                await service.setVault(backlog)
                await service.vaultChanged(root: backlog, paths: nil, checkpoint: nil)
            }
        }
        let api = LocalAPI(model: model, ask: ask)
        func log(_ line: String) { FileHandle.standardError.write(Data(String(format: "[%6.1fs] ", elapsed()).appending(line + "\n").utf8)) }

        try await model.prepareSpeech()
        let started = await api.respond(.startRecording, HTTPRequest(method: "POST", path: "/v1/recording/start", body: Data(#"{"title":"Live session replay"}"#.utf8)))
        guard started.status == 200, let id = model.meeting?.id else { throw CaptureError.message("Start failed: \(String(decoding: started.body, as: UTF8.self))") }
        log("recording \(id) · system + microphone replay at \(pace)×")
        let opened = await api.respond(.openDocument(id), HTTPRequest(method: "POST", path: "/v1/meetings/\(id)/document"))
        guard opened.status == 200, var document = model.meetingSnapshot(id)?.document else { throw CaptureError.message("Document failed: \(String(decoding: opened.body, as: UTF8.self))") }
        let header = document.source.hasSuffix("- ") ? String(document.source.dropLast(2)) : document.source
        var typed: [(id: String, text: String, at: Double)] = []
        var pressure: [String] = [], liveLines: [String: Double] = [:]
        var lagSamples: [[String: Double]] = []
        var nextNote = 0
        var timeline: [Replay.Row] = [], seenLines: [String: String] = [:], revisions: [String: Int] = [:]
        func observeLines(_ settled: Bool = false) {
            guard let snapshot = model.meetingSnapshot(id) else { return }
            for note in snapshot.notes ?? [] {
                let text = note.line.text ?? "", key = text + "|" + note.line.state.rawValue
                guard seenLines[note.id] != key || settled else { continue }
                if !text.isEmpty && seenLines[note.id]?.hasPrefix(text + "|") != true { revisions[note.id, default: 0] += 1 }
                seenLines[note.id] = key
                timeline.append(Replay.Row(case_id: "audio", note_id: note.id, at: elapsed(), cause: settled ? "stop" : "audio",
                    state: settled ? (text.isEmpty ? "quiet" : "settled") : (text.isEmpty ? "listening" : "answered"),
                    text: text, revision: revisions[note.id, default: 0], jot: note.text,
                    available_segment_ids: snapshot.orderedSegments.map(\.id), evidence: note.line.evidence ?? [], background: []))
            }
        }
        let observation = NotificationCenter.default.addObserver(forName: .workScribeNotesChanged, object: model, queue: .main) { _ in
            MainActor.assumeIsolated { observeLines() }
        }
        defer { NotificationCenter.default.removeObserver(observation) }
        let end = length + 4
        while elapsed() < end {
            lagSamples.append(["at": elapsed(), "lag": model.transcriptLag.values.max() ?? 0, "wall_time": Date().timeIntervalSince1970, "generating": generator.active ? 1 : 0, "footprint_bytes": Double(replayFootprint()), "thermal": Double(ProcessInfo.processInfo.thermalState.rawValue)])
            if nextNote < notes.count, elapsed() >= notes[nextNote].at {
                // The note is typed into the vault file, then synced the way the plugin syncs it.
                typed.append(("n\(nextNote + 1)", notes[nextNote].text, elapsed())); nextNote += 1
                var text = header, blocks: [NoteDocument.Block] = []
                for line in typed {
                    let from = (text as NSString).length
                    text += line.text
                    blocks.append(.init(id: line.id, from: from, to: (text as NSString).length, text: line.text, at: line.at, section: ""))
                    text += "\n"
                }
                try text.write(toFile: document.path, atomically: true, encoding: .utf8)
                var next = document; next.source = text; next.blocks = blocks
                let synced = await api.respond(.syncDocument(id), HTTPRequest(method: "PATCH", path: "/v1/meetings/\(id)/document", body: try JSONEncoder().encode(next)))
                guard synced.status == 200, let saved = model.meetingSnapshot(id)?.document else { throw CaptureError.message("Sync failed: \(String(decoding: synced.body, as: UTF8.self))") }
                document = saved
                log("typed jot \(typed.count)")
            }
            let state = "\(model.recordingPressure)"
            if pressure.last != state {
                pressure.append(state)
                log("pressure \(state) · lag " + model.transcriptLag.sorted { $0.key < $1.key }.map { "\($0.key) \(String(format: "%.1f", $0.value)) s" }.joined(separator: ", "))
            }
            for note in model.meetingSnapshot(id)?.notes ?? [] where note.line.text != nil && liveLines[note.text] == nil {
                liveLines[note.text] = elapsed(); log("live AI line appeared")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let beforeStop = try await model.runtime.diagnostics()
        log("stop")
        let stopStarted = Date()
        let stopped = await api.respond(.stopRecording, HTTPRequest(method: "POST", path: "/v1/recording/stop"))
        let stopSeconds = Date().timeIntervalSince(stopStarted)
        let afterStop = try await model.runtime.diagnostics()
        log("stopped in \(String(format: "%.1f", stopSeconds)) s · \(model.phase) · \(model.message)")
        guard stopped.status == 200, let final = model.meetingSnapshot(id) else { throw CaptureError.message("Stop failed") }

        var failures: [String] = []
        let enrolledSamples = model.voices.flatMap(\.samples).filter { $0.meetingID == id }.count
        if afterStop.openedStreams != beforeStop.openedStreams { failures.append("Stop opened a new recognition stream") }
        if final.transcriptPolishedForEnd != nil { failures.append("Stop replaced the streaming transcript") }
        let cacheMediaAfter = cacheRoots.reduce(into: Set<String>()) { $0.formUnion(capturedMedia(in: $1)) }
        let mediaFiles = capturedMedia(in: root).union(cacheMediaAfter.subtracting(cacheMediaBefore)).sorted()
        if !mediaFiles.isEmpty { failures.append("Recorded media on disk: " + mediaFiles.joined(separator: ", ")) }
        if (final.notes ?? []).contains(where: { $0.line.state == .listening || $0.line.state == .found }) { failures.append("notes still pending after Stop") }
        if !EchoFilter.matches(final.segments).isEmpty { failures.append("echo duplicates remain after streaming flush") }
        if model.phase != "ready" { failures.append("phase is \(model.phase): \(model.message)") }
        var note = ""
        try await model.retentionService?.finalize(id, allowRebase: true)
        note = (try? String(contentsOfFile: model.meetingSnapshot(id)?.vaultPath ?? "", encoding: .utf8)) ?? ""
        observeLines(true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var timelineData = Data()
        for row in timeline { timelineData.append(try encoder.encode(row)); timelineData.append(10) }
        try timelineData.write(to: output.appendingPathComponent("audio-timeline.jsonl"), options: .atomic)
        let activeSamples = lagSamples.filter { sample in generator.spans.contains { $0.contains(sample["wall_time"] ?? -1) } }
        let activeLags = activeSamples.compactMap { $0["lag"] }.sorted()
        if activeSamples.isEmpty { failures.append("no ASR samples overlapped E4B generation") }
        let lags = lagSamples.compactMap { $0["lag"] }.sorted()
        let searchIndex = await indexService?.index
        let counts = try searchIndex?.counts()
        let report: [String: Any] = [
            "duration_seconds": length, "sample_period_seconds": 0.1, "generation_calls": generator.count, "generation_intervals": generator.spans.map { [$0.lowerBound, $0.upperBound] }, "calls": generator.receipts.map { call in ["job": call.job, "note_id": call.note_id ?? "", "prompt_sha256": call.prompt_sha256, "seconds": call.seconds, "prompt_tokens": call.stats.promptTokens, "generated_tokens": call.stats.generatedTokens, "ttft_ms": call.stats.ttftMs] as [String: Any] }, "generation_seconds": generator.seconds, "asr_generating_sample_count": activeSamples.count, "asr_lag_generating_p95_seconds": activeLags.isEmpty ? NSNull() : activeLags[min(activeLags.count - 1, Int(Double(activeLags.count - 1) * 0.95))] as Any, "asr_lag_generating_max_seconds": activeLags.last as Any? ?? NSNull(), "indexing": indexing, "asr_lag_samples": lagSamples,
            "asr_lag_p95_seconds": lags.isEmpty ? 0 : lags[min(lags.count - 1, Int(Double(lags.count - 1) * 0.95))],
            "asr_lag_max_seconds": lags.last ?? 0,
            "index_chunks": counts?.chunks ?? 0, "index_vectors": counts?.vectors ?? 0,
            "pace": pace, "stop_seconds": stopSeconds,
            "pressure_states": pressure, "message_after_stop": model.message,
            "live_lines_before_stop": liveLines.count, "notes": final.notes?.count ?? 0,
            "notes_state": (final.notes ?? []).map { "\($0.text) → \($0.line.state.rawValue)" },
            "ai_lines": (final.notes ?? []).map { [$0.text, $0.line.text ?? "—"] },
            "actions": (final.actionItems ?? []).map(\.text), "brief": final.brief ?? NSNull(),
            "system_segments": final.segments.filter { $0.source == "system" }.count,
            "microphone_segments": final.segments.filter { $0.source == "microphone" }.count,
            "echo_segments_removed": final.echoSegments?.count ?? 0, "unheard_fragments_set_aside": final.unheardSegments?.count ?? 0,
            "echo_duplicates_remaining": EchoFilter.matches(final.segments).count,
            "transcript_source": "streaming", "recorded_media_files": mediaFiles,
            "recognition_streams_opened_during_stop": afterStop.openedStreams - beforeStop.openedStreams,
            "recognition_streams_flushed_at_stop": afterStop.finishedStreams - beforeStop.finishedStreams,
            "live_voice_vectors": final.voiceEmbeddings?.count ?? 0, "enrolled_voice_samples": enrolledSamples, "failures": failures]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("audio.json"), options: .atomic)
        FileHandle.standardOutput.write(Data("\n".utf8))
        if !note.isEmpty { try note.write(to: output.appendingPathComponent("finalized.md"), atomically: true, encoding: .utf8) }
        await indexService?.shutdown()
        withExtendedLifetime(indexHookup) {}
        await model.runtime.stop()
        await generator.release()
        if !failures.isEmpty { throw CaptureError.message("Live session failed: " + failures.joined(separator: "; ")) }
    }
}

private extension AVAudioFile {
    var duration: Double { Double(length) / processingFormat.sampleRate }
}

/// Locking only metadata, never the actual generation, so the ASR sampler stays responsive.
final class ReplayAudioModel: TextModel, @unchecked Sendable {
    let wrapped: any TextModel
    private let lock = NSLock()
    private var running = false, calls = 0, elapsed = 0.0
    private var intervals: [ClosedRange<Double>] = []
    private var records: [ReplayModels.Call] = []
    init(wrapped: any TextModel) { self.wrapped = wrapped }
    var displayName: String { wrapped.displayName }
    var backend: TextBackend { wrapped.backend }
    var isAvailable: Bool { wrapped.isAvailable }
    var receipts: [ReplayModels.Call] { lock.withLock { records } }
    var spans: [ClosedRange<Double>] { lock.withLock { intervals } }
    var active: Bool { lock.withLock { running } }
    var count: Int { lock.withLock { calls } }
    var seconds: Double { lock.withLock { elapsed } }
    func generate(_ request: TextRequest) async throws -> TextGeneration {
        let started = ContinuousClock.now
        lock.withLock { running = true; calls += 1 }
        defer { lock.withLock { running = false; elapsed += (ContinuousClock.now - started).milliseconds / 1000 } }
        let value = try await wrapped.generate(request)
        let end = Date().timeIntervalSince1970
        lock.withLock {
            intervals.append((end - value.stats.totalMs / 1000)...end)
            records.append(.init(cause: "audio", job: request.instruction.hasPrefix(BriefPolicy.promptHead) ? "brief" : request.instruction.hasPrefix(NotePrompt.topicsHead) ? "topics" : "line", note_id: request.noteID, model: displayName, prompt_sha256: replayHash(request.instruction), stats: value.stats, seconds: (ContinuousClock.now - started).milliseconds / 1000))
        }
        return value
    }
    func stream(_ request: TextRequest) -> AsyncThrowingStream<String, Error> { wrapped.stream(request) }
    func prewarm(_ request: TextRequest?) async { await wrapped.prewarm(request) }
    func release() async { await wrapped.release() }
}

func replayFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? info.phys_footprint : 0
}
