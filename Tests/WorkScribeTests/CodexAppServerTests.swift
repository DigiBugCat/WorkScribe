import XCTest
import WorkScribeCore
@testable import WorkScribe

/// `CodexAppServer` against a stand-in for `codex app-server`: a real child process speaking the
/// protocol over real pipes. What these cover that the reducer tests cannot: launching, line
/// framing across chunk boundaries, ordering between output and exit, the clock, and cancellation
/// through Swift tasks. Nothing here touches the network or a real Codex.
final class CodexAppServerTests: XCTestCase {
    /// A scripted server. `MODE` picks how it misbehaves.
    private static let script = #"""
        import json, os, sys, time
        mode = os.environ.get("MODE", "ok")
        log = os.environ.get("LOG")
        def out(message, split=False):
            line = json.dumps(message) + "\n"
            if split:                      # one line in two writes: the reader must reassemble it
                half = len(line) // 2
                sys.stdout.write(line[:half]); sys.stdout.flush(); time.sleep(0.02); sys.stdout.write(line[half:])
            else: sys.stdout.write(line)
            sys.stdout.flush()
        def note(text):
            if log:
                with open(log, "a") as f: f.write(text + "\n")
        note("start")
        if mode == "silent": time.sleep(60)
        threads = 0
        for raw in sys.stdin:
            m = json.loads(raw); method = m.get("method"); rid = m.get("id"); p = m.get("params") or {}
            note(method or "reply")
            if method == "initialize": out({"id": rid, "result": {"userAgent": "fake"}})
            elif method == "mcpServerStatus/list":
                out({"id": rid, "result": {"data": [{"name": "notion"}] if mode == "tools" else []}})
            elif method == "account/read":
                account = None if mode == "signedout" else {"type": "chatgpt", "email": "a@b.c", "planType": "pro"}
                out({"id": rid, "result": {"account": account, "requiresOpenaiAuth": True}})
            elif method == "thread/start":
                threads += 1
                out({"id": rid, "result": {"thread": {"id": "T%d" % threads}, "model": "fake-model", "approvalPolicy": "never",
                                           "sandbox": {"type": "readOnly", "networkAccess": False}, "instructionSources": []}})
            elif method == "turn/start":
                t = p["threadId"]; u = "U" + t
                prompt = p["input"][0]["text"]
                note("prompt:" + prompt)
                out({"id": rid, "result": {"turn": {"id": u}}})
                if mode == "die": os._exit(3)
                if mode == "hang": continue
                if mode == "shell":
                    out({"method": "item/started", "params": {"threadId": t, "turnId": u, "item": {"type": "commandExecution", "id": "X"}}})
                    continue
                for word in ("echo:", prompt):
                    out({"method": "item/agentMessage/delta", "params": {"threadId": t, "turnId": u, "itemId": "I", "delta": word}}, split=True)
                    if mode == "slow": time.sleep(0.4)
                out({"method": "thread/tokenUsage/updated", "params": {"threadId": t, "turnId": u, "tokenUsage": {"last": {"inputTokens": 11, "cachedInputTokens": 5, "outputTokens": 2}}}})
                out({"method": "turn/completed", "params": {"threadId": t, "turn": {"id": u, "status": "completed"}}})
            elif method == "turn/interrupt":
                note("interrupted")
                out({"id": rid, "result": {}})
                out({"method": "turn/completed", "params": {"threadId": p["threadId"], "turn": {"id": p["turnId"], "status": "interrupted"}}})
            elif rid is not None: out({"id": rid, "result": {}})
        note("eof")
        """#

    private var folder: URL!
    private var log: URL { folder.appendingPathComponent("log.txt") }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("codex-fake-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.script.write(to: folder.appendingPathComponent("fake.py"), atomically: true, encoding: .utf8)
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), "needs /usr/bin/python3")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    private func server(_ mode: String, timing: CodexAppServer.Timing = .init(handshake: .seconds(5), stall: .seconds(5), limit: .seconds(20), idle: .seconds(60), tick: .milliseconds(50))) -> CodexAppServer {
        let script = folder.appendingPathComponent("fake.py").path
        return CodexAppServer(settings: .init(workspace: folder.path, attempts: 2), timing: timing,
                              executable: { URL(fileURLWithPath: "/usr/bin/python3") }, arguments: [script],
                              environment: ["MODE": mode, "LOG": log.path, "CODEX_HOME": folder.path], open: { _ in })
    }
    private func logged() -> [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }

    func testATurnOverRealPipes() async throws {
        let server = server("ok")
        let pieces = Pieces()
        let reply = try await server.generate(CodexRequest(prompt: "hello world")) { pieces.add($0) }
        XCTAssertEqual(reply.text, "echo:hello world"); XCTAssertEqual(pieces.joined, "echo:hello world")
        XCTAssertEqual(reply.usage.cachedInputTokens, 5); XCTAssertEqual(reply.model, "fake-model")
        // A second request reuses the process.
        let second = try await server.generate(CodexRequest(prompt: "again"))
        XCTAssertEqual(second.text, "echo:again")
        XCTAssertEqual(logged().filter { $0 == "start" }.count, 1)
        await server.shutdown()
    }

    func testRequestsInParallelEachGetTheirOwnText() async throws {
        let server = server("ok")
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for index in 0..<6 { group.addTask { (index, try await server.generate(CodexRequest(prompt: "p\(index)")).text) } }
            for try await (index, text) in group { XCTAssertEqual(text, "echo:p\(index)") }
        }
        await server.shutdown()
    }

    func testCancellingTheTaskInterruptsTheTurn() async throws {
        let server = server("hang")
        let task = Task { try await server.generate(CodexRequest(prompt: "wait")) }
        try await waitFor { self.logged().contains("prompt:wait") }
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
        try await waitFor { self.logged().contains("interrupted") }
        await server.shutdown()
    }

    func testAStalledTurnFailsInsteadOfHanging() async throws {
        let server = server("hang", timing: .init(handshake: .seconds(5), stall: .milliseconds(300), limit: .seconds(20), idle: .seconds(60), tick: .milliseconds(50)))
        do { _ = try await server.generate(CodexRequest(prompt: "wait")); XCTFail("expected a failure") }
        catch let failure as CodexFailure { XCTAssertEqual(failure, .failed("Codex stopped responding")) }
        await server.shutdown()
    }

    func testTheProcessDyingMidTurnFailsTheCallerAndTheNextRequestStartsANewOne() async throws {
        let server = server("die")
        do { _ = try await server.generate(CodexRequest(prompt: "x")); XCTFail("expected a failure") }
        catch let failure as CodexFailure { XCTAssertEqual(failure, .failed("Codex stopped")) }
        do { _ = try await server.generate(CodexRequest(prompt: "y")); XCTFail("expected a failure") } catch is CodexFailure {}
        XCTAssertEqual(logged().filter { $0 == "start" }.count, 2)
        await server.shutdown()
    }

    func testAProcessThatNeverAnswersIsGivenUpOn() async throws {
        let server = server("silent", timing: .init(handshake: .milliseconds(200), stall: .seconds(5), limit: .seconds(20), idle: .seconds(60), tick: .milliseconds(50)))
        do { _ = try await server.generate(CodexRequest(prompt: "x")); XCTFail("expected a failure") }
        catch let failure as CodexFailure { guard case .unavailable = failure else { return XCTFail("\(failure)") } }
        XCTAssertEqual(logged().filter { $0 == "start" }.count, 2, "two starts were allowed")
    }

    func testAToolServerOrAToolEndsTheConnectionWithoutSendingMore() async throws {
        var server = server("tools")
        do { _ = try await server.generate(CodexRequest(prompt: "SECRET")); XCTFail("expected a failure") }
        catch let failure as CodexFailure { guard case .unsafe = failure else { return XCTFail("\(failure)") } }
        XCTAssertFalse(logged().contains("thread/start")); XCTAssertFalse(logged().contains("prompt:SECRET"))

        try? FileManager.default.removeItem(at: log)
        server = self.server("shell")
        do { _ = try await server.generate(CodexRequest(prompt: "first")); XCTFail("expected a failure") }
        catch let failure as CodexFailure { guard case .unsafe = failure else { return XCTFail("\(failure)") } }
        do { _ = try await server.generate(CodexRequest(prompt: "second")); XCTFail("expected a failure") }
        catch let failure as CodexFailure { guard case .unsafe = failure else { return XCTFail("\(failure)") } }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(logged().contains("prompt:second"), "nothing is sent on a connection that used a tool")
        XCTAssertEqual(logged().filter { $0 == "start" }.count, 1, "and no new process is started behind the person's back")
    }

    func testSignedOutFailsWithoutStartingAThread() async throws {
        let server = server("signedout")
        do { _ = try await server.generate(CodexRequest(prompt: "x")); XCTFail("expected a failure") }
        catch let failure as CodexFailure { XCTAssertEqual(failure, .signedOut) }
        XCTAssertFalse(logged().contains("thread/start"))
        await server.shutdown()
    }

    func testAMissingExecutableIsReportedNotRetriedForever() async throws {
        let server = CodexAppServer(settings: .init(workspace: folder.path, attempts: 3), executable: { nil }, arguments: [],
                                    environment: ["CODEX_HOME": folder.path], open: { _ in })
        do { _ = try await server.generate(CodexRequest(prompt: "x")); XCTFail("expected a failure") }
        catch let failure as CodexFailure { XCTAssertEqual(failure, .unavailable("it isn’t installed")) }
    }

    func testTheTextModelStreamsAndStopsAtTheMarker() async throws {
        let model = CodexTextModel(server: server("slow"))
        var text = ""
        for try await piece in model.stream(TextRequest("streamed", maxTokens: 50)) { text += piece }
        XCTAssertEqual(text, "echo:streamed")
        let line = try await model.generate(TextRequest("a</output>b", maxTokens: 50, stop: "</output>"))
        XCTAssertEqual(line.text, "echo:a"); XCTAssertEqual(line.stats.reusedTokens, 0, "the turn was cut before usage arrived")
        await model.release()
    }

    private func waitFor(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(25)) }
        XCTFail("condition not met in time")
    }
    private final class Pieces: @unchecked Sendable {
        private let lock = NSLock(); private var all: [String] = []
        func add(_ piece: String) { lock.withLock { all.append(piece) } }
        var joined: String { lock.withLock { all.joined() } }
    }
}
