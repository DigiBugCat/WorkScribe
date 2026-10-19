import AVFoundation
import ScreenCaptureKit
import CoreMedia
import WorkScribeCore

enum CaptureError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Convert once and stream in capture order. Meeting audio never touches disk.
final class AudioTrack {
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var closed = false
    private var level: Float = 0
    private var firstSample: Date?
    private var silence = SilenceMeter()
    var firstCaptureAt: Date? { lock.withLock { firstSample } }
    /// Several seconds of input and not one non-zero sample.
    var isDigitallySilent: Bool { lock.withLock { silence.isDigitalSilence() } }
    var hasSamples: Bool { lock.withLock { silence.frames > 0 } }
    let backlog: AudioBacklog
    var onFailure: ((Error) -> Void)?
    init() { backlog = AudioBacklog() }
    func accept(_ input: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        do {
            if converter?.inputFormat != input.format { converter = AVAudioConverter(from: input.format, to: format) }
            guard let converter else { throw CaptureError.message("Cannot convert this audio input") }
            let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / input.format.sampleRate)) + 256
            let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
            var supplied = false, error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return input
            }
            if let error { throw error }
            guard status != .error else { throw CaptureError.message("Audio conversion failed") }
            if output.frameLength > 0 {
                if firstSample == nil { firstSample = Date() }
                level = Self.loudness(output)
                silence.add(UnsafeBufferPointer(start: output.int16ChannelData![0], count: Int(output.frameLength)))
                let bytes = Data(bytes: output.int16ChannelData![0], count: Int(output.frameLength) * 2)
                try backlog.append(bytes)
            }
        } catch { closed = true; backlog.finish(throwing: error); onFailure?(error) }
    }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        closed = true; level = 0; backlog.finish()
    }
    /// Loudness of the most recent buffer, 0 (silence, below -60 dBFS) to 1.
    func currentLevel() -> Float {
        lock.lock(); defer { lock.unlock() }
        return closed ? 0 : level
    }
    private static func loudness(_ buffer: AVAudioPCMBuffer) -> Float {
        let count = Int(buffer.frameLength)
        guard count > 0, let samples = buffer.int16ChannelData?[0] else { return 0 }
        var sum: Float = 0
        for index in 0..<count { let value = Float(samples[index]) / 32768; sum += value * value }
        let decibels = 10 * log10(max(sum / Float(count), 1e-10))
        return min(1, max(0, (decibels + 60) / 60))
    }
}

/// Where a recording's audio comes from. `AudioCapture` is the Mac's devices; verification replays files.
protocol AudioCapturing: AnyObject {
    var onFailure: ((Error) -> Void)? { get set }
    var onChange: (() -> Void)? { get set }
    var systemAudioError: Error? { get }
    var microphoneError: Error? { get }
    var echoCancelling: Bool { get }
    var microphoneDevice: String? { get }
    func start(microphone: AudioTrack, system: AudioTrack?) async throws
    func stop() async
}

/// System audio (ScreenCaptureKit) and the microphone (AVAudioEngine) start and fail independently.
/// The microphone uses Apple voice processing, so a call playing through the Mac's speakers is
/// cancelled from the mic before it reaches recognition. `EchoFilter` is the transcript-level net.
final class AudioCapture: NSObject, AudioCapturing, SCStreamOutput, SCStreamDelegate {
    private var engine: AVAudioEngine?
    private var screen: SCStream?
    private var systemTrack: AudioTrack?
    private var microphoneTrack: AudioTrack?
    private var configurationObserver: NSObjectProtocol?
    private var stopped = false
    private var restarts: [Date] = []
    /// Called when every source has failed. A single source failing is reported through `onChange`.
    var onFailure: ((Error) -> Void)?
    /// A source started, stopped or recovered while recording.
    var onChange: (() -> Void)?
    /// Set when system audio couldn't start; the microphone keeps recording.
    private(set) var systemAudioError: Error?
    /// Set when the microphone couldn't be opened; system audio keeps recording.
    private(set) var microphoneError: Error?
    /// Whether Apple's echo cancellation is active on the microphone right now.
    private(set) var echoCancelling = false
    /// Off only by explicit preference or for isolated verification.
    static var wantsEchoCancellation: Bool {
        ProcessInfo.processInfo.environment["WORKSCRIBE_DISABLE_VOICE_PROCESSING"] != "1"
            && UserDefaults.standard.object(forKey: "echoCancellation") as? Bool ?? true
    }
    var systemWorking: Bool { systemTrack != nil && systemAudioError == nil }
    var microphoneDevice: String? { AVCaptureDevice.default(for: .audio)?.localizedName }

    /// Throws only when neither source could start.
    func start(microphone: AudioTrack, system: AudioTrack?) async throws {
        microphoneTrack = microphone; systemTrack = system
        systemAudioError = nil; microphoneError = nil; stopped = false
        if let system { do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { throw CaptureError.message("No display available for system audio capture") }
            let config = SCStreamConfiguration()
            config.width = 2; config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.capturesAudio = true; config.excludesCurrentProcessAudio = true
            config.sampleRate = 48000; config.channelCount = 2
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "WorkScribe.system-audio"))
            screen = stream
            try await stream.startCapture()
        } catch {
            // A missing Screen Recording permission must not cost the microphone track.
            systemAudioError = error; screen = nil
            system.finish(); systemTrack = nil
        } }
        do { try await startMicrophone() }
        catch {
            // A microphone that cannot open (AVFAudio -308 while a call app reconfigures the
            // devices, no input, permission) must not cost the call audio that already works.
            microphoneError = error
            microphone.finish(); microphoneTrack = nil
            guard systemTrack != nil else { throw error }
        }
    }

    /// CoreAudio builds an aggregate device for AVAudioEngine. While a call app is switching the
    /// route (a Bluetooth headset moving to its call profile, Zoom's own device appearing) that
    /// briefly fails with -308 or -10868. Retry with a fresh engine, then without voice processing.
    private func startMicrophone() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw CaptureError.message("Allow microphone access in System Settings → Privacy & Security → Microphone.")
        }
        var lastError: Error = CaptureError.message("No working microphone found")
        for attempt in 0..<4 {
            if stopped { return }
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 400_000_000) }
            // The last attempt is the plain input path: less to go wrong, no echo cancellation.
            let voiceProcessing = Self.wantsEchoCancellation && attempt < 3
            do { try openEngine(voiceProcessing: voiceProcessing); return }
            catch { lastError = error; closeEngine() }
        }
        throw lastError
    }

    private func openEngine(voiceProcessing: Bool) throws {
        guard let track = microphoneTrack else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        echoCancelling = false
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            // Ducking would turn the call down for the person and for the system-audio track.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            // Voice processing is a duplex unit: give it a silent output path.
            engine.mainMixerNode.outputVolume = 0
            echoCancelling = true
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.message("No working microphone found") }
        // Voice processing can expose several channels; the processed voice is channel 0.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in track.accept(buffer) }
        self.engine = engine
        engine.prepare()
        try engine.start()
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.microphoneRouteChanged() }
        }
    }

    private func closeEngine() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0); engine.stop()
            if engine.inputNode.isVoiceProcessingEnabled { try? engine.inputNode.setVoiceProcessingEnabled(false) }
        }
        engine = nil; echoCancelling = false
    }

    /// The input or output device changed mid-call (headset plugged in, AirPods switching
    /// profile). AVAudioEngine stops itself; reopen it on the new route.
    @MainActor private func microphoneRouteChanged() {
        // Voice processing can announce its own reconfiguration while it keeps running.
        guard !stopped, microphoneTrack != nil, engine?.isRunning != true else { return }
        restarts = restarts.filter { Date().timeIntervalSince($0) < 60 } + [Date()]
        closeEngine()
        guard restarts.count <= 5 else {
            // A flapping device must not spin the engine; say so instead.
            microphoneError = CaptureError.message("The microphone kept changing")
            microphoneTrack?.finish(); microphoneTrack = nil
            if systemTrack == nil { onFailure?(microphoneError!) } else { onChange?() }
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await startMicrophone(); microphoneError = nil }
            catch {
                microphoneError = error
                microphoneTrack?.finish(); microphoneTrack = nil
                if systemTrack == nil { onFailure?(error) }
            }
            onChange?()
        }
    }

    func stop() async {
        stopped = true
        closeEngine()
        // End the in-memory queues immediately, even if ScreenCaptureKit takes time to stop.
        microphoneTrack?.finish(); systemTrack?.finish()
        microphoneTrack = nil; systemTrack = nil
        let stopping = screen; screen = nil
        if let stopping { try? await stopping.stopCapture() }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.screen === stream, !self.stopped else { return }
            // Losing the call audio is a degraded recording while the microphone still works.
            self.screen = nil; self.systemAudioError = error
            self.systemTrack?.finish(); self.systemTrack = nil
            if self.microphoneTrack == nil { self.onFailure?(error) } else { self.onChange?() }
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let description = sampleBuffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        var needed = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: &needed,
            bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment), blockBufferOut: nil)
        let memory = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
        defer { memory.deallocate() }
        let list = memory.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil,
            bufferListOut: list, bufferListSize: needed, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment), blockBufferOut: &block)
        guard status == noErr, let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list) else { return }
        withExtendedLifetime(block) { systemTrack?.accept(buffer) }
    }
}
