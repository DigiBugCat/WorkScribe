import AVFoundation
import ScreenCaptureKit
import CoreMedia
import WorkScribeCore

enum CaptureError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Each track is converted once, saved losslessly, then forwarded in capture order.
final class AudioTrack {
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var file: AVAudioFile?
    private var closed = false
    private var level: Float = 0
    private var firstSample: Date?
    var firstCaptureAt: Date? { lock.withLock { firstSample } }
    let backlog: AudioBacklog
    var onFailure: ((Error) -> Void)?
    init(url: URL) throws {
        backlog = try AudioBacklog(url: url.appendingPathExtension("transcribing.pcm"))
        file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
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
                try file?.write(from: output)
                level = Self.loudness(output)
                let bytes = Data(bytes: output.int16ChannelData![0], count: Int(output.frameLength) * 2)
                try backlog.append(bytes)
            }
        } catch { closed = true; file = nil; backlog.finish(throwing: error); onFailure?(error) }
    }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        closed = true; file = nil; level = 0; backlog.finish()
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

final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var engine: AVAudioEngine?
    private var screen: SCStream?
    private var systemTrack: AudioTrack?
    private var microphoneTrack: AudioTrack?
    var onFailure: ((Error) -> Void)?
    /// Set when system audio couldn't start; the microphone keeps recording.
    private(set) var systemAudioError: Error?
    func start(microphone: AudioTrack, system: AudioTrack?) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw CaptureError.message("Allow microphone access in System Settings → Privacy & Security → Microphone.")
        }
        microphoneTrack = microphone; systemTrack = system
        systemAudioError = nil
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
        let engine = AVAudioEngine(); self.engine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.message("No working microphone found") }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in microphone.accept(buffer) }
        engine.prepare(); try engine.start()
    }
    func stop() async {
        engine?.inputNode.removeTap(onBus: 0); engine?.stop(); engine = nil
        // Close audio files immediately, even if ScreenCaptureKit takes time to stop.
        microphoneTrack?.finish(); systemTrack?.finish()
        microphoneTrack = nil; systemTrack = nil
        let stopping = screen; screen = nil
        if let stopping { try? await stopping.stopCapture() }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onFailure?(error) }
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
