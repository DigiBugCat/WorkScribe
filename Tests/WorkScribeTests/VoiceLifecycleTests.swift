import XCTest
import AVFoundation
import WorkScribeCore
@testable import WorkScribe

actor FixedVoiceEngine: VoiceExtracting {
    func extract(meeting: Meeting, folder: URL) async throws -> [ExtractedVoice] {
        meeting.segments.filter { VoiceMatching.eligible($0, in: meeting) }.map { ExtractedVoice(segmentID: $0.id, vector: [1, 0, 0]) }
    }
}
actor DelayedVoiceEngine: VoiceExtracting {
    var continuation: CheckedContinuation<[ExtractedVoice], Error>?
    var segmentID = ""
    func extract(meeting: Meeting, folder: URL) async throws -> [ExtractedVoice] {
        segmentID = meeting.segments[0].id
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func wait() async { while continuation == nil { await Task.yield() } }
    func finish() { continuation?.resume(returning: [ExtractedVoice(segmentID: segmentID, vector: [1,0,0])]); continuation = nil }
}

@MainActor final class VoiceLifecycleTests: XCTestCase {
    func fixture(engine: any VoiceExtracting = FixedVoiceEngine()) throws -> (AppModel, Meeting) {
        let store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var entry = Meeting(title: "Synthetic voice test")
        entry.status = "complete"; entry.sourceOffsets = ["system": 0]
        entry.segments = [
            Segment(source: "system", speaker: "system:speaker-1", start: 0, end: 4, text: "First statement."),
            Segment(source: "system", speaker: "system:speaker-1", start: 5, end: 9, text: "Second statement."),
            Segment(source: "microphone", speaker: "microphone:speaker-1", start: 5, end: 9, text: "Separate source.")]
        try store.save(entry)
        return (AppModel(store: store, voiceEngine: engine), entry)
    }
    func drain(_ model: AppModel) async { for task in model.voiceTasks.values { await task.value } }

    func testStaleInferenceCannotRestoreClearedName() async throws {
        let engine = DelayedVoiceEngine()
        let (model, entry) = try fixture(engine: engine); defer { try? FileManager.default.removeItem(at: model.store.root) }
        model.nameSpeaker(meetingID: entry.id, segmentID: entry.segments[0].id, name: "Alex", profileID: nil, wholeSpeaker: true, remember: true)
        await engine.wait()
        let task = model.voiceTasks[entry.id]
        model.clearSpeaker(meetingID: entry.id, segmentID: entry.segments[0].id, wholeSpeaker: true)
        await engine.finish(); await task?.value
        XCTAssertNil(try model.store.load(entry.id).assignment(for: entry.segments[0]))
        XCTAssertTrue(model.voices[0].samples.isEmpty)
        XCTAssertTrue(model.voiceJobs.isEmpty)
    }
    func testAudioCropUsesSourceOffset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("system.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64000)!
        buffer.frameLength = 64000
        for i in 0..<64000 { buffer.floatChannelData![0][i] = i < 16000 ? 0.1 : 0.7 }
        try autoreleasepool { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let meetingTime = 6.0, sourceOffset = 5.0
        let samples = try await VoiceEngine().readSamples(url: url, start: meetingTime - sourceOffset, duration: 3)
        XCTAssertEqual(samples.count, 48000)
        XCTAssertEqual(samples[0], 0.7, accuracy: 0.001)
        XCTAssertEqual(samples.last!, 0.7, accuracy: 0.001)
    }
    func testScopeUndoAndRawIdentity() async throws {
        let (model, entry) = try fixture(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        XCTAssertTrue(model.nameSpeaker(meetingID: entry.id, segmentID: entry.segments[0].id, name: "Alex", profileID: nil, wholeSpeaker: true, remember: true))
        await drain(model)
        var saved = try model.store.load(entry.id)
        XCTAssertEqual(saved.speakerName(for: entry.segments[1]), "Alex")
        XCTAssertEqual(saved.speakerName(for: entry.segments[2]), "Speaker 1")
        XCTAssertEqual(saved.segments[0].speaker, "system:speaker-1")
        XCTAssertEqual(model.voices[0].samples.count, 2)
        model.nameSpeaker(meetingID: entry.id, segmentID: entry.segments[1].id, name: "Morgan", profileID: nil, wholeSpeaker: false, remember: false)
        await drain(model)
        saved = try model.store.load(entry.id)
        XCTAssertEqual(saved.speakerName(for: entry.segments[0]), "Alex")
        XCTAssertEqual(saved.speakerName(for: entry.segments[1]), "Morgan")
        XCTAssertEqual(model.voices[0].samples.count, 1)
        model.undoSpeakerChange(id: entry.id); await drain(model)
        XCTAssertEqual(try model.store.load(entry.id).speakerName(for: entry.segments[1]), "Alex")
        model.clearSpeaker(meetingID: entry.id, segmentID: entry.segments[1].id, wholeSpeaker: false)
        saved = try model.store.load(entry.id)
        XCTAssertEqual(saved.speakerName(for: entry.segments[1]), "Speaker 1")
        XCTAssertEqual(saved.speakerName(for: entry.segments[0]), "Alex")
    }
    func testSuggestionsDoNotSelfTrainAndForgetPreservesNames() async throws {
        let (model, first) = try fixture(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        model.nameSpeaker(meetingID: first.id, segmentID: first.segments[0].id, name: "Alex", profileID: nil, wholeSpeaker: true, remember: true)
        await drain(model)
        var second = first; second.id = UUID().uuidString
        try model.store.save(second)
        model.analyzeVoices(id: second.id); await drain(model)
        let saved = try model.store.load(second.id)
        XCTAssertEqual(saved.speakerSuggestions?["system:speaker-1"]?.name, "Alex")
        XCTAssertNil(saved.assignment(for: second.segments[0]))
        XCTAssertEqual(model.voices[0].samples.count, 2)
        let profileID = model.voices[0].id
        model.renameVoice(id: profileID, name: "Alex Renamed")
        XCTAssertEqual(try model.store.load(first.id).speakerName(for: first.segments[0]), "Alex")
        model.forgetVoice(id: profileID)
        XCTAssertTrue(model.voices.isEmpty)
        XCTAssertEqual(try model.voiceStore.load().count, 0)
        XCTAssertEqual(try model.store.load(first.id).speakerName(for: first.segments[0]), "Alex")
        XCTAssertNil(try model.store.load(second.id).speakerSuggestions?["system:speaker-1"])
    }
    func testForgetWhileInferenceIsRunningCannotRecreateProfile() async throws {
        let engine = DelayedVoiceEngine()
        let (model, entry) = try fixture(engine: engine); defer { try? FileManager.default.removeItem(at: model.store.root) }
        model.nameSpeaker(meetingID: entry.id, segmentID: entry.segments[0].id, name: "Alex", profileID: nil, wholeSpeaker: true, remember: true)
        await engine.wait()
        let task = model.voiceTasks[entry.id]
        model.forgetVoice(id: model.voices[0].id)
        await engine.finish(); await task?.value
        XCTAssertTrue(model.voices.isEmpty)
        XCTAssertTrue(try model.voiceStore.load().isEmpty)
        XCTAssertNil(try model.store.load(entry.id).assignment(for: entry.segments[0])?.profileID)
        XCTAssertTrue(model.voiceJobs.isEmpty)
    }
}
