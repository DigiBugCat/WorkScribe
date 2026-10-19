import AVFoundation
import XCTest
import WorkScribeCore
@testable import WorkScribe

private struct QuietEnhancer: Enriching {
    func enhance(_ meeting: Meeting, incremental: Bool) async throws -> Enrichment? { nil }
}
private struct DelayedEnhancer: Enriching {
    let nanoseconds: UInt64
    func enhance(_ meeting: Meeting, incremental: Bool) async throws -> Enrichment? {
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
        // Stop says plainly why there are no final notes.
        XCTAssertEqual(model.message, "Recording saved · no final notes: the local model stopped responding while writing the final lines")
    }

    func testQuitWhileRecordingSavesOnceWithoutAsking() async throws {
        let quit = RecordingQuit()
        var saves = 0, teardowns = 0
        let blocked = quit.request(phase: "recording", blocked: true, save: { saves += 1 }, complete: { teardowns += 1 })
        XCTAssertEqual(blocked, .terminateCancel); XCTAssertFalse(quit.pending)
        await Task.yield()
        XCTAssertEqual(saves, 0); XCTAssertEqual(teardowns, 0)
        let accepted = quit.request(phase: "recording", blocked: false, save: {
            saves += 1
            try? await Task.sleep(nanoseconds: 20_000_000)
        }, complete: { teardowns += 1 })
        let repeated = quit.request(phase: "finalizing", blocked: false,
                                    save: { XCTFail("second save") }, complete: { XCTFail("second teardown") })
        XCTAssertEqual(accepted, .terminateLater); XCTAssertEqual(repeated, .terminateLater)
        XCTAssertEqual(teardowns, 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(saves, 1); XCTAssertEqual(teardowns, 1)
    }

    func testSlowRecognizerDrainsMemoryQueueWithoutFiles() async throws {
        let track = AudioTrack()
        var captureFailed = false
        track.onFailure = { _ in captureFailed = true }
        let buffer = AVAudioPCMBuffer(pcmFormat: track.format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        for i in 0..<1600 { buffer.int16ChannelData![0][i] = 1234 }
        for _ in 0..<200 { track.accept(buffer) }
        XCTAssertFalse(captureFailed)
        XCTAssertEqual(track.backlog.pendingSeconds, 20, accuracy: 0.01)
        let recognizer = SlowRecognizer()
        let pump = Task {
            while let data = try await track.backlog.next() {
                try await recognizer.write(data)
                track.backlog.acknowledge(data.count)
            }
        }
        for _ in 0..<10 { track.accept(buffer) }
        track.finish()
        try await pump.value
        let bytes = await recognizer.count
        XCTAssertEqual(bytes, 210 * 1600 * 2)
        XCTAssertEqual(track.backlog.pendingSeconds, 0)
        XCTAssertFalse(captureFailed)
    }

    func testOverflowFailsExplicitlyInsteadOfPersistingOrDroppingAudio() {
        let track = AudioTrack()
        var failures = 0
        track.onFailure = { _ in failures += 1 }
        let buffer = AVAudioPCMBuffer(pcmFormat: track.format, frameCapacity: 16000)!
        buffer.frameLength = 16000
        for i in 0..<16000 { buffer.int16ChannelData![0][i] = 1000 }
        for _ in 0..<35 { track.accept(buffer) }
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(track.backlog.pendingSeconds, 30)
        track.backlog.discard()
        XCTAssertEqual(track.backlog.pendingSeconds, 0)
    }

    func testCrashWriterHelper() throws {
        guard let path = ProcessInfo.processInfo.environment["WORKSCRIBE_CRASH_FIXTURE"] else { return }
        let store = MeetingStore(root: URL(fileURLWithPath: path))
        let model = AppModel(store: store)
        for phase in ["starting", "recording", "finalizing"] {
            var meeting = Meeting(title: phase); meeting.status = phase
            meeting.segments = [Segment(source: "system", speaker: "system:speaker-1", start: 0, end: 1, text: "Saved before termination")]
            model.meeting = meeting; model.phase = phase; try model.save()
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
            let files = try FileManager.default.contentsOfDirectory(atPath: store.directory(meeting.id).path)
            XCTAssertEqual(files, ["transcript.json"])
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
