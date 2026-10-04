import AVFoundation
import ScreenCaptureKit
import CoreMedia

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
    let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    init(url: URL) throws {
        var captured: AsyncThrowingStream<Data, Error>.Continuation!
        stream = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(128)) { captured = $0 }
        continuation = captured
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
                try file?.write(from: output)
                let bytes = Data(bytes: output.int16ChannelData![0], count: Int(output.frameLength) * 2)
                if case .dropped = continuation.yield(bytes) {
                    throw CaptureError.message("Transcription cannot keep up with audio. Recording stopped; captured audio is saved.")
                }
            }
        } catch { closed = true; file = nil; continuation.finish(throwing: error) }
    }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        closed = true; file = nil; continuation.finish()
    }
}

final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var engine: AVAudioEngine?
    private var screen: SCStream?
    private var systemTrack: AudioTrack?
    private var microphoneTrack: AudioTrack?
    var onFailure: ((Error) -> Void)?
    func start(microphone: AudioTrack, system: AudioTrack?) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw CaptureError.message("Allow microphone access in System Settings → Privacy & Security → Microphone.")
        }
        microphoneTrack = microphone; systemTrack = system
        if system != nil {
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
        }
        let engine = AVAudioEngine(); self.engine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.message("No working microphone found") }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in microphone.accept(buffer) }
        engine.prepare(); try engine.start()
    }
    func stop() async {
        engine?.inputNode.removeTap(onBus: 0); engine?.stop(); engine = nil
        if let screen { try? await screen.stopCapture() }; screen = nil
        microphoneTrack?.finish(); systemTrack?.finish()
        microphoneTrack = nil; systemTrack = nil
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
