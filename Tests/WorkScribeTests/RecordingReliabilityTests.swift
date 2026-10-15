import AVFoundation
import XCTest
import WorkScribeCore
@testable import WorkScribe

private struct QuietEnhancer: NoteEnhancing {
    func enhance(_ meeting: Meeting, incremental: Bool, missedTopics: Bool) async throws -> NoteDraft? { nil }
}
private struct DelayedEnhancer: NoteEnhancing {
    let nanoseconds: UInt64
    func enhance(_ meeting: Meeting, incremental: Bool, missedTopics: Bool) async throws -> NoteDraft? {
        try await Task.sleep(nanoseconds: nanoseconds)
        return nil
    }
}

private actor SlowRecognizer {
    var count = 0
    func write(_ data: Data) async throws {
        try await Task.sleep(nanoseconds: 2_000_000)
        count += data.count
    }
}

@MainActor final class RecordingReliabilityTests: XCTestCase {
    func testAPIDuplicateStopJoinsFinalizationAndStartNamesItsState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: MeetingStore(root: root))
        let ask = AskService(model: model, store: ConversationStore(root: root.appendingPathComponent("Chats")), generator: nil)
        let api = LocalAPI(model: model, ask: ask)
        let old = NoteEnhancementScheduler.shared.enhancer
        NoteEnhancementScheduler.shared.enhancer = DelayedEnhancer(nanoseconds: 100_000_000)
        defer { NoteEnhancementScheduler.shared.enhancer = old }
        model.meeting = Meeting(title: "Synthetic"); model.phase = "recording"; try model.save()
        let request = HTTPRequest(method: "POST", path: "/v1/recording/stop")
        async let first = api.respond(.stopRecording, request)
        while model.phase == "recording" { await Task.yield() }
        let start = await api.respond(.startRecording, .init(method: "POST", path: "/v1/recording/start"))
        XCTAssertEqual(start.status, 409)
        XCTAssertTrue(String(decoding: start.body, as: UTF8.self).contains("finalizing"))
        let second = await api.respond(.stopRecording, request)
        let firstResponse = await first
        XCTAssertEqual(firstResponse.status, 200); XCTAssertEqual(second.status, 200)
        XCTAssertFalse(api.status().recording); XCTAssertFalse(model.busy)
    }

    func testStalledAIPassCannotStrandRecordingInFinalizing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: MeetingStore(root: root)); model.stallTimeout = 0.04
        let old = NoteEnhancementScheduler.shared.enhancer
        NoteEnhancementScheduler.shared.enhancer = DelayedEnhancer(nanoseconds: 10_000_000_000)
        defer { NoteEnhancementScheduler.shared.enhancer = old }
        model.meeting = Meeting(title: "Synthetic"); model.phase = "recording"; try model.save()
        await model.stop()
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.meeting?.status, "complete")
        XCTAssertTrue(model.message.contains("final AI pass could not finish"))
    }

    func testCancelQuitKeepsServicesAndRepeatedQuitSavesOnce() async throws {
        let quit = RecordingQuit()
        var saves = 0, teardowns = 0
        let denied = quit.request(phase: "recording", blocked: false, confirm: { false },
                                  save: { saves += 1 }, complete: { teardowns += 1 })
        XCTAssertEqual(denied, .terminateCancel); XCTAssertFalse(quit.pending)
        await Task.yield()
        XCTAssertEqual(saves, 0); XCTAssertEqual(teardowns, 0)
        let accepted = quit.request(phase: "recording", blocked: false, confirm: { true }, save: {
            saves += 1
            try? await Task.sleep(nanoseconds: 20_000_000)
        }, complete: { teardowns += 1 })
        let repeated = quit.request(phase: "finalizing", blocked: false, confirm: { XCTFail("second dialog"); return false },
                                    save: { XCTFail("second save") }, complete: { XCTFail("second teardown") })
        XCTAssertEqual(accepted, .terminateLater); XCTAssertEqual(repeated, .terminateLater)
        XCTAssertEqual(teardowns, 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(saves, 1); XCTAssertEqual(teardowns, 1)
    }

    func testSlowRecognizerNeverStopsOrDropsAudioAndDrainsAfterStop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("system.wav")
        let track = try AudioTrack(url: url)
        var captureFailed = false
        track.onFailure = { _ in captureFailed = true }
        let buffer = AVAudioPCMBuffer(pcmFormat: track.format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        for i in 0..<1600 { buffer.int16ChannelData![0][i] = 1234 }
        // Far beyond the previous 128-buffer limit, while recognition makes no progress.
        for _ in 0..<500 { track.accept(buffer) }
        XCTAssertFalse(captureFailed)
        XCTAssertEqual(track.backlog.pendingSeconds, 50, accuracy: 0.01)
        XCTAssertEqual(RecordingPressure(lag: 2), .screenPaused)
        XCTAssertEqual(RecordingPressure(lag: 6), .aiPaused)
        XCTAssertEqual(RecordingPressure(lag: track.backlog.pendingSeconds), .transcriptDelayed)
        let recognizer = SlowRecognizer()
        let pump = Task {
            while let data = try await track.backlog.next() {
                try await recognizer.write(data)
                track.backlog.acknowledge(data.count)
            }
        }
        // Capture still accepts new audio while draining. Stop closes only the capture writer.
        for _ in 0..<10 { track.accept(buffer) }
        track.finish()
        try await pump.value
        let bytes = await recognizer.count
        XCTAssertEqual(bytes, 510 * 1600 * 2)
        XCTAssertEqual(track.backlog.pendingSeconds, 0)
        XCTAssertEqual(RecordingPressure(lag: 0), .normal)
        XCTAssertFalse(captureFailed)
        let saved = try AVAudioFile(forReading: url)
        XCTAssertEqual(saved.length, 510 * 1600)
        let all = AVAudioPCMBuffer(pcmFormat: saved.processingFormat, frameCapacity: AVAudioFrameCount(saved.length))!
        try saved.read(into: all)
        XCTAssertEqual(all.frameLength, 510 * 1600)
        XCTAssertEqual(all.floatChannelData![0][Int(all.frameLength)-1], Float(1234) / 32768, accuracy: 0.00001)
    }

    func testCrashWriterHelper() throws {
        guard let path = ProcessInfo.processInfo.environment["WORKSCRIBE_CRASH_FIXTURE"] else { return }
        let store = MeetingStore(root: URL(fileURLWithPath: path))
        let model = AppModel(store: store)
        for phase in ["starting", "recording", "finalizing"] {
            var meeting = Meeting(title: phase); meeting.status = phase
            meeting.segments = [Segment(source: "system", speaker: "system:speaker-1", start: 0, end: 1, text: "Saved before termination")]
            model.meeting = meeting; model.phase = phase; try model.save()
            let folder = try store.directory(meeting.id)
            // A durable PCM journal and a deliberately unfinished WAV header.
            let backlog = try AudioBacklog(url: folder.appendingPathComponent("system.wav.transcribing.pcm"))
            try backlog.append(Data(repeating: 0, count: 32_000))
            try Data("unfinished".utf8).write(to: folder.appendingPathComponent("system.wav"))
        }
        try Data().write(to: URL(fileURLWithPath: path).appendingPathComponent("ready"))
        while true { Thread.sleep(forTimeInterval: 1) } // Parent terminates this process; no graceful shutdown.
    }

    func testTerminationMidRecordingAndRelaunchRecoversEveryPhase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "WorkScribeTests.RecordingReliabilityTests/testCrashWriterHelper", Bundle(for: Self.self).bundleURL.path]
        child.environment = ProcessInfo.processInfo.environment.merging(["WORKSCRIBE_CRASH_FIXTURE": root.path]) { _, b in b }
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path), child.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path), "child recording fixture did not start")
        child.terminate(); child.waitUntilExit()
        let store = MeetingStore(root: root)
        let relaunched = AppModel(store: store)
        XCTAssertFalse(relaunched.busy); XCTAssertEqual(relaunched.phase, "ready")
        XCTAssertEqual(relaunched.library.count, 3)
        for meeting in relaunched.library {
            XCTAssertEqual(meeting.status, "interrupted")
            XCTAssertNotNil(meeting.endedAt); XCTAssertNotNil(meeting.purgeAt)
            XCTAssertEqual(meeting.segments.first?.text, "Saved before termination")
            let wav = try AVAudioFile(forReading: store.directory(meeting.id).appendingPathComponent("system.wav"))
            XCTAssertEqual(wav.length, 16_000)
        }
        let again = AppModel(store: store)
        XCTAssertEqual(again.library.map(\.endedAt), relaunched.library.map(\.endedAt))
    }

    func testConcurrentStopAndQuitSettleWithoutHalfQuit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: MeetingStore(root: root))
        let old = NoteEnhancementScheduler.shared.enhancer
        NoteEnhancementScheduler.shared.enhancer = QuietEnhancer()
        defer { NoteEnhancementScheduler.shared.enhancer = old }
        model.meeting = Meeting(title: "Synthetic recording"); model.phase = "recording"
        try model.save()
        async let stop: Void = model.stop()
        async let quit: Void = model.prepareToQuit()
        _ = await (stop, quit)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.meeting?.status, "complete")
        XCTAssertEqual(try model.store.load(model.meeting!.id).status, "complete")
    }

    func testStalledFinalizerReturnsButProgressingBacklogGetsTime() async throws {
        do {
            try await RecordingDeadline.wait(stall: 0.04) { try await Task.sleep(nanoseconds: 10_000_000_000) }
            XCTFail("stalled work must not hold finalizing forever")
        } catch is RecordingDeadline.Stalled { }
        var remaining = 5.0
        try await RecordingDeadline.wait(stall: 0.04, progress: { remaining }) {
            for _ in 0..<5 { try await Task.sleep(nanoseconds: 20_000_000); remaining -= 1 }
        }
        XCTAssertEqual(remaining, 0)
    }
}
