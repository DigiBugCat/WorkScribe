import AVFoundation
import XCTest
import WorkScribeCore
@testable import WorkScribe

private struct NoAudioTitle: TitleGenerating {
    func generate(transcript: String) async throws -> String { "Memory capture test" }
}
private struct NoAudioNotes: Enriching {
    func enhance(_ meeting: Meeting, incremental: Bool) async throws -> Enrichment? { nil }
}
private actor LiveVoiceFixture: VoiceExtracting {
    var crops: [[Float]] = []
    func embedding(samples: [Float]) async throws -> [Float] {
        crops.append(samples)
        return [1] + Array(repeating: 0, count: 255)
    }
    func extract(meeting: Meeting, folder: URL) async throws -> [ExtractedVoice] {
        (meeting.voiceEmbeddings ?? [:]).map { ExtractedVoice(segmentID: $0.key, vector: $0.value) }
    }
}
@MainActor private final class MemorySpeech: SpeechStreaming {
    var onEvent: (([String: Any]) -> Void)?
    var pushes = 0, finishes = 0
    func connect() async throws {}
    func write(_ data: Data) async throws {
        pushes += 1
        if pushes == 4 {
            onEvent?(["type": "transcript.completed", "transcript": "Remember this live voice.",
                      "words": [["word": "Remember this live voice.", "start": 0.0, "end": 4.0, "speaker": 1]]])
        }
    }
    func finish() async throws { finishes += 1 }
    func close() {}
}
private final class MemoryCapture: AudioCapturing {
    var onFailure: ((Error) -> Void)?
    var onChange: (() -> Void)?
    var systemAudioError: Error? { nil }
    var microphoneError: Error? { nil }
    var echoCancelling: Bool { false }
    var microphoneDevice: String? { "Synthetic microphone" }
    private var track: AudioTrack?
    func start(microphone: AudioTrack, system: AudioTrack?) async throws {
        track = microphone
        let buffer = AVAudioPCMBuffer(pcmFormat: microphone.format, frameCapacity: 64000)!
        buffer.frameLength = 64000
        for i in 0..<64000 { buffer.int16ChannelData![0][i] = 5000 }
        microphone.accept(buffer)
    }
    func stop() async { track?.finish(); track = nil }
}

@MainActor final class NoAudioTests: XCTestCase {
    func testRecordingStopAndEnrolmentUseOnlyLiveBuffers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldEnhancer = NoteEnhancementScheduler.shared.enhancer
        let oldEmbedder = Enrich.embedderSource
        NoteEnhancementScheduler.shared.enhancer = NoAudioNotes()
        Enrich.embedderSource = { nil }
        defer {
            NoteEnhancementScheduler.shared.enhancer = oldEnhancer
            Enrich.embedderSource = oldEmbedder
        }
        let cache = root.appendingPathComponent("Caches")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let previousCache = ProcessInfo.processInfo.environment["WORKSCRIBE_RUNTIME_CACHE"]
        setenv("WORKSCRIBE_RUNTIME_CACHE", cache.path, 1)
        defer {
            if let previousCache { setenv("WORKSCRIBE_RUNTIME_CACHE", previousCache, 1) }
            else { unsetenv("WORKSCRIBE_RUNTIME_CACHE") }
        }
        let voice = LiveVoiceFixture(), speech = MemorySpeech()
        let model = AppModel(store: MeetingStore(root: root), titleGenerator: NoAudioTitle(), voiceEngine: voice)
        let oldSettings = (model.includeSystemAudio, model.screenCaptureEnabled)
        defer { model.includeSystemAudio = oldSettings.0; model.screenCaptureEnabled = oldSettings.1 }
        model.speechReady = true; model.includeSystemAudio = false; model.screenCaptureEnabled = false
        model.makeCapture = { MemoryCapture() }; model.makeConnection = { speech }
        await model.start()
        for _ in 0..<200 where model.meeting?.voiceEmbeddings?.isEmpty != false {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let segment = try XCTUnwrap(model.meeting?.segments.first)
        let id = try XCTUnwrap(model.meeting?.id)
        XCTAssertEqual(model.meeting?.voiceEmbeddings?[segment.id]?.count, 256)
        let crops = await voice.crops
        XCTAssertEqual(crops.count, 1); XCTAssertEqual(crops.first?.count, 64000)
        XCTAssertTrue(model.nameSpeaker(meetingID: id, segmentID: segment.id, name: "Live speaker", profileID: nil, wholeSpeaker: true, remember: true))
        for task in model.voiceTasks.values { await task.value }
        XCTAssertEqual(model.voices.first?.samples.count, 1)
        let before = model.meeting!.segments
        await model.stop()
        XCTAssertEqual(speech.pushes, 4); XCTAssertEqual(speech.finishes, 1)
        XCTAssertEqual(model.meeting?.segments.map(\.id), before.map(\.id))
        XCTAssertEqual(model.meeting?.segments.map(\.text), before.map(\.text))
        XCTAssertNil(model.meeting?.transcriptPolishedForEnd)
        XCTAssertEqual(model.phase, "ready", model.message)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.compactMap { ($0 as? URL)?.lastPathComponent }
        XCTAssertEqual(Set(files.filter { $0.contains(".") }), ["transcript.json", "voices.json"])
    }
}
