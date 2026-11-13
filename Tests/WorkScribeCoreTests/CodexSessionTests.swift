import XCTest
@testable import WorkScribeCore

/// `CodexSession` against `formal/tla/CodexSession.tla`.
///
/// The scripted tests walk each action of the model once, on the real reducer. The last test plays
/// the model's environment (a server that may answer, stall, use a tool or die; callers that may
/// cancel or time out) in thousands of random orders and checks the model's properties after
/// every step.
final class CodexSessionTests: XCTestCase {
    // MARK: A hand-driven session

    /// The reducer plus everything it asked for, in order.
    private struct Harness {
        var session = CodexSession(settings: .init(model: nil, effort: "low", workspace: "/tmp/ws-empty", attempts: 3))
        var sent: [[String: Any]] = []
        var effects: [CodexSession.Effect] = []
        var finished: [UUID: Result<CodexReply, CodexFailure>] = [:]
        var deltas: [UUID: String] = [:]
        var kills = 0, spawns: [Int] = []
        var doubleFinish = false

        @discardableResult mutating func handle(_ event: CodexSession.Event) -> [CodexSession.Effect] {
            let out = session.handle(event)
            for effect in out {
                effects.append(effect)
                switch effect {
                case .send(let line): sent.append((try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:])
                case .finish(let id, let result): if finished[id] != nil { doubleFinish = true }; finished[id] = result
                case .delta(let id, let text): deltas[id, default: ""] += text
                case .kill: kills += 1
                case .spawn(let number): spawns.append(number)
                default: break
                }
            }
            return out
        }
        var methods: [String] { sent.compactMap { $0["method"] as? String } }
        func id(of method: String, last: Bool = true) -> Int? {
            let matches = sent.filter { $0["method"] as? String == method }
            return ((last ? matches.last : matches.first)?["id"] as? NSNumber)?.intValue
        }
        mutating func receive(_ message: [String: Any]) {
            handle(.received(spawn: session.spawn, try! JSONSerialization.data(withJSONObject: message)))
        }
        mutating func reply(_ method: String, _ result: [String: Any]) { receive(["id": id(of: method)!, "result": result]) }
        mutating func note(_ method: String, _ parameters: [String: Any]) { receive(["method": method, "params": parameters]) }

        /// initialize → checks → ready, signed in.
        mutating func handshake(servers: [[String: Any]] = [], account: [String: Any]? = ["type": "chatgpt", "email": "a@b.c", "planType": "pro"]) {
            reply("initialize", ["userAgent": "x"])
            reply("mcpServerStatus/list", ["data": servers])
            reply("account/read", ["account": account ?? NSNull(), "requiresOpenaiAuth": true])
        }
        static let cleanThread: [String: Any] = ["thread": ["id": "T1"], "model": "gpt-test", "approvalPolicy": "never",
                                                 "sandbox": ["type": "readOnly", "networkAccess": false], "instructionSources": []]
        /// Up to a running turn "U1" on thread "T1".
        mutating func running(_ request: CodexRequest = CodexRequest(prompt: "PROMPT")) -> UUID {
            let id = UUID()
            handle(.generate(id: id, request)); handshake()
            reply("thread/start", Self.cleanThread)
            reply("turn/start", ["turn": ["id": "U1"]])
            return id
        }
        mutating func say(_ text: String, item: String = "I1") {
            note("item/agentMessage/delta", ["threadId": "T1", "turnId": "U1", "itemId": item, "delta": text])
        }
        mutating func complete(_ status: String = "completed", error: String? = nil) {
            var turn: [String: Any] = ["id": "U1", "status": status]
            if let error { turn["error"] = ["message": error] }
            note("turn/completed", ["threadId": "T1", "turn": turn])
        }
    }

    private func text(_ result: Result<CodexReply, CodexFailure>?) -> String? { try? result?.get().text }
    private func failure(_ result: Result<CodexReply, CodexFailure>?) -> CodexFailure? {
        if case .failure(let failure) = result { return failure }
        return nil
    }

    // MARK: The model's actions, one at a time

    func testRequestSpawnsChecksThenSendsThePromptOnce() {
        var h = Harness()
        let id = UUID()
        h.handle(.generate(id: id, CodexRequest(prompt: "PROMPT")))
        XCTAssertEqual(h.spawns, [1]); XCTAssertEqual(h.methods, ["initialize"])
        h.reply("initialize", [:])
        XCTAssertEqual(h.methods, ["initialize", "initialized", "mcpServerStatus/list", "account/read"])
        h.reply("mcpServerStatus/list", ["data": []])
        XCTAssertFalse(h.methods.contains("thread/start"), "nothing starts until both checks answered")
        h.reply("account/read", ["account": ["type": "chatgpt", "email": "a@b.c", "planType": "pro"], "requiresOpenaiAuth": true])
        XCTAssertEqual(h.session.process, .ready)
        let start = h.sent.last!
        XCTAssertEqual(start["method"] as? String, "thread/start")
        let parameters = start["params"] as! [String: Any]
        XCTAssertEqual(parameters["ephemeral"] as? Bool, true)
        XCTAssertEqual(parameters["sandbox"] as? String, "read-only")
        XCTAssertEqual(parameters["approvalPolicy"] as? String, "never")
        XCTAssertFalse(String(describing: h.sent).contains("PROMPT"), "the prompt is not in thread/start")
        h.reply("thread/start", Harness.cleanThread)
        let turn = h.sent.last!["params"] as! [String: Any]
        XCTAssertEqual((turn["input"] as! [[String: Any]]).first?["text"] as? String, "PROMPT")
        XCTAssertEqual(turn["effort"] as? String, "low")
        h.reply("turn/start", ["turn": ["id": "U1"]])
        h.say("Hello"); h.say(" there")
        XCTAssertEqual(h.deltas[id], "Hello there")
        h.note("thread/tokenUsage/updated", ["threadId": "T1", "turnId": "U1", "tokenUsage": ["last": ["inputTokens": 40, "cachedInputTokens": 30, "outputTokens": 3]]])
        h.complete()
        let reply = try? h.finished[id]?.get()
        XCTAssertEqual(reply?.text, "Hello there"); XCTAssertEqual(reply?.usage.cachedInputTokens, 30); XCTAssertEqual(reply?.model, "gpt-test")
        XCTAssertEqual(h.methods.last, "thread/unsubscribe")
        XCTAssertEqual(h.session.active, 0); XCTAssertFalse(h.doubleFinish)
    }

    func testCancelWhileTheThreadIsStartingSendsNoPrompt() {
        var h = Harness(); let id = UUID()
        h.handle(.generate(id: id, CodexRequest(prompt: "PROMPT"))); h.handshake()
        h.handle(.cancel(id: id))
        XCTAssertEqual(failure(h.finished[id]), .cancelled, "the caller is told at once")
        h.reply("thread/start", Harness.cleanThread)
        XCTAssertEqual(h.methods.last, "thread/unsubscribe")
        XCTAssertFalse(h.methods.contains("turn/start")); XCTAssertFalse(String(describing: h.sent).contains("PROMPT"))
    }

    func testCancelWhileTheTurnIsStartingInterruptsItOnceItHasAnID() {
        var h = Harness(); let id = UUID()
        h.handle(.generate(id: id, CodexRequest(prompt: "PROMPT"))); h.handshake()
        h.reply("thread/start", Harness.cleanThread)
        h.handle(.cancel(id: id))
        XCTAssertFalse(h.methods.contains("turn/interrupt"), "there is no turn id to interrupt yet")
        h.reply("turn/start", ["turn": ["id": "U1"]])
        XCTAssertTrue(h.methods.contains("turn/interrupt"))
        h.say("late"); h.complete("interrupted")
        XCTAssertNil(h.deltas[id]); XCTAssertEqual(h.finished.count, 1); XCTAssertFalse(h.doubleFinish)
    }

    func testCancelWhileRunningInterruptsAndDropsWhatArrivesLate() {
        var h = Harness(); let id = h.running()
        h.say("Hel")
        h.handle(.cancel(id: id))
        XCTAssertEqual(h.methods.last, "turn/interrupt")
        h.say("lo"); h.complete()
        XCTAssertEqual(h.deltas[id], "Hel"); XCTAssertEqual(failure(h.finished[id]), .cancelled); XCTAssertFalse(h.doubleFinish)
    }

    func testTimeoutFailsTheCallerAndOnlyOnce() {
        var h = Harness(); let id = h.running()
        h.handle(.timeout(id: id)); h.handle(.timeout(id: id)); h.complete()
        XCTAssertEqual(failure(h.finished[id]), .failed("Codex stopped responding")); XCTAssertFalse(h.doubleFinish)
    }

    func testCancelBeforeTheRequestArrivesIsRemembered() {
        var h = Harness(); let id = UUID()
        h.handle(.cancel(id: id))
        h.handle(.generate(id: id, CodexRequest(prompt: "PROMPT")))
        XCTAssertEqual(failure(h.finished[id]), .cancelled); XCTAssertTrue(h.sent.isEmpty); XCTAssertTrue(h.spawns.isEmpty)
    }

    func testAToolItemEndsTheConnectionForEveryone() {
        var h = Harness(); let first = h.running()
        let second = UUID(); h.handle(.generate(id: second, CodexRequest(prompt: "OTHER")))
        h.say("partial")
        let sentBefore = h.sent.count
        h.note("item/started", ["threadId": "T1", "turnId": "U1", "item": ["type": "commandExecution", "id": "X"]])
        guard case .unsafe = h.session.process else { return XCTFail("not unsafe") }
        guard case .unsafe = failure(h.finished[first]), case .unsafe = failure(h.finished[second]) else { return XCTFail("callers not told") }
        XCTAssertEqual(h.kills, 1); XCTAssertEqual(h.sent.count, sentBefore, "nothing more is written")
        // Whatever the dying process still printed, and whoever asks next: nothing is sent.
        h.say(" more"); h.complete()
        let third = UUID(); h.handle(.generate(id: third, CodexRequest(prompt: "AGAIN")))
        guard case .unsafe = failure(h.finished[third]) else { return XCTFail("a later request must fail at once") }
        XCTAssertEqual(h.sent.count, sentBefore); XCTAssertEqual(h.spawns, [1]); XCTAssertFalse(h.doubleFinish)
        // An explicit reset allows another try.
        h.handle(.reset); XCTAssertEqual(h.session.process, .down)
    }

    func testAServerRequestIsTreatedLikeATool() {
        var h = Harness(); let id = h.running()
        h.receive(["id": 99, "method": "item/commandExecution/requestApproval", "params": ["threadId": "T1"]])
        guard case .unsafe = failure(h.finished[id]) else { return XCTFail() }
    }

    func testAToolServerInTheHomeStopsBeforeAnyThread() {
        var h = Harness(); let id = UUID()
        h.handle(.generate(id: id, CodexRequest(prompt: "PROMPT")))
        h.reply("initialize", [:])
        h.reply("mcpServerStatus/list", ["data": [["name": "notion"], ["name": "gmail"]]])
        guard case .unsafe(let why) = failure(h.finished[id]) else { return XCTFail() }
        XCTAssertTrue(why.contains("gmail, notion"))
        XCTAssertFalse(h.methods.contains("thread/start")); XCTAssertEqual(h.kills, 1)
    }

    func testAThreadThatIsNotIsolatedNeverGetsThePrompt() {
        for (field, value) in [("instructionSources", ["/Users/x/.codex/AGENTS.md"] as Any), ("approvalPolicy", "on-request"),
                               ("sandbox", ["type": "workspaceWrite"]), ("sandbox", ["type": "readOnly", "networkAccess": true])] {
            var h = Harness(); let id = UUID()
            h.handle(.generate(id: id, CodexRequest(prompt: "PROMPT"))); h.handshake()
            var thread = Harness.cleanThread; thread[field] = value
            h.reply("thread/start", thread)
            guard case .unsafe = failure(h.finished[id]) else { XCTFail("\(field) accepted"); continue }
            XCTAssertFalse(h.methods.contains("turn/start"), field)
        }
    }

    func testProcessExitFailsTheTurnAndRestartsForWhoeverWaits() {
        var h = Harness(); let running = h.running()
        h.handle(.exited(spawn: 1, reason: nil))
        XCTAssertEqual(failure(h.finished[running]), .failed("Codex stopped"))
        XCTAssertEqual(h.spawns, [1], "nobody is waiting, so nothing restarts")
        // Three starts in a row that never get through the handshake: the waiting caller is told.
        let waiting = UUID(); h.handle(.generate(id: waiting, CodexRequest(prompt: "P")))
        XCTAssertEqual(h.spawns, [1, 2])
        h.handle(.exited(spawn: 2, reason: "boom")); h.handle(.exited(spawn: 3, reason: "boom"))
        XCTAssertNil(h.finished[waiting]); XCTAssertEqual(h.spawns, [1, 2, 3, 4])
        h.handle(.exited(spawn: 4, reason: "boom"))
        XCTAssertEqual(failure(h.finished[waiting]), .unavailable("boom")); XCTAssertEqual(h.session.process, .down)
        XCTAssertEqual(h.spawns.count, 4, "no further start until someone asks again")
    }

    func testHandshakeTimeoutKillsAndRestarts() {
        var h = Harness(); let id = UUID()
        h.handle(.generate(id: id, CodexRequest(prompt: "P")))
        h.handle(.handshakeTimeout(spawn: 1))
        XCTAssertEqual(h.kills, 1); XCTAssertEqual(h.spawns, [1, 2]); XCTAssertNil(h.finished[id])
        h.handle(.handshakeTimeout(spawn: 1)); XCTAssertEqual(h.kills, 1, "a timeout for an earlier process is ignored")
    }

    func testOutputFromAnEarlierProcessIsIgnored() {
        var h = Harness(); let id = UUID()
        h.handle(.generate(id: id, CodexRequest(prompt: "P")))
        h.handle(.handshakeTimeout(spawn: 1))
        let stale = try! JSONSerialization.data(withJSONObject: ["id": 1, "result": [:]])
        XCTAssertTrue(h.session.handle(.received(spawn: 1, stale)).isEmpty)
        XCTAssertTrue(h.session.handle(.exited(spawn: 1, reason: nil)).isEmpty)
        XCTAssertEqual(h.session.process, .starting)
    }

    func testSignedOutFailsFastAndSignInOpensThePage() {
        var h = Harness(); let id = UUID()
        h.handle(.generate(id: id, CodexRequest(prompt: "PROMPT"))); h.handshake(account: nil)
        XCTAssertEqual(failure(h.finished[id]), .signedOut); XCTAssertFalse(h.methods.contains("thread/start"))
        h.handle(.signIn)
        XCTAssertEqual(h.methods.last, "account/login/start")
        // A request made during the browser sign-in does not wait for it.
        let during = UUID(); h.handle(.generate(id: during, CodexRequest(prompt: "P")))
        XCTAssertEqual(failure(h.finished[during]), .signedOut)
        h.reply("account/login/start", ["type": "chatgpt", "authUrl": "https://example.test/login", "loginId": "L1"])
        XCTAssertTrue(h.effects.contains(.open(url: "https://example.test/login")))
        XCTAssertEqual(h.session.account, .signingIn(url: "https://example.test/login"))
        h.note("account/login/completed", ["success": true, "loginId": "L1"])
        h.reply("account/read", ["account": ["type": "chatgpt", "email": "a@b.c", "planType": "pro"], "requiresOpenaiAuth": true])
        XCTAssertEqual(h.session.account, .signedIn(email: "a@b.c", plan: "pro"))
        let after = UUID(); h.handle(.generate(id: after, CodexRequest(prompt: "P")))
        XCTAssertEqual(h.methods.last, "thread/start")
    }

    func testAnUnauthorizedTurnMeansSignedOut() {
        var h = Harness(); let id = h.running()
        h.complete("failed", error: "unexpected status 401 Unauthorized: Missing bearer")
        XCTAssertEqual(failure(h.finished[id]), .signedOut); XCTAssertEqual(h.session.account, .signedOut)
    }

    func testStopMarkerFirstLineAndCeilingEndTheTurnEarly() {
        var h = Harness(); var id = h.running(CodexRequest(prompt: "P", stop: "</output>"))
        h.say("* **Topic:** fine.</out"); h.say("put> trailing")
        XCTAssertEqual(text(h.finished[id]), "* **Topic:** fine."); XCTAssertEqual(h.methods.last, "turn/interrupt")
        h.complete("interrupted"); XCTAssertFalse(h.doubleFinish)

        h = Harness(); id = h.running(CodexRequest(prompt: "P", firstLine: true))
        h.say("\n  Budget review"); XCTAssertNil(h.finished[id])
        h.say(" notes\nSecond line")
        XCTAssertEqual(text(h.finished[id]), "Budget review notes")

        h = Harness(); id = h.running(CodexRequest(prompt: "P", maxCharacters: 5))
        h.say("123"); h.say("456789")
        XCTAssertEqual(text(h.finished[id]), "12345"); XCTAssertEqual(h.deltas[id], "12345")
    }

    func testCommentaryIsNotTheAnswerAndACompletedMessageFillsInMissingDeltas() {
        var h = Harness(); var id = h.running()
        h.note("item/started", ["threadId": "T1", "turnId": "U1", "item": ["type": "agentMessage", "id": "C", "phase": "commentary", "text": ""]])
        h.say("thinking out loud", item: "C")
        h.note("item/started", ["threadId": "T1", "turnId": "U1", "item": ["type": "agentMessage", "id": "A", "phase": "final_answer", "text": ""]])
        h.say("answer", item: "A"); h.complete()
        XCTAssertEqual(text(h.finished[id]), "answer")

        h = Harness(); id = h.running()
        h.note("item/completed", ["threadId": "T1", "turnId": "U1", "item": ["type": "agentMessage", "id": "A", "text": "whole answer"]])
        h.complete()
        XCTAssertEqual(text(h.finished[id]), "whole answer")
    }

    func testDisconnectTellsEveryoneAndTheNextRequestStartsOver() {
        var h = Harness(); let id = h.running()
        h.handle(.disconnect)
        XCTAssertEqual(failure(h.finished[id]), .signedOut); XCTAssertEqual(h.kills, 1)
        XCTAssertEqual(h.session.process, .down); XCTAssertEqual(h.session.account, .signedOut)
        XCTAssertTrue(h.session.handle(.exited(spawn: 1, reason: nil)).isEmpty, "the exit that follows is not a second failure")
        let next = UUID(); h.handle(.generate(id: next, CodexRequest(prompt: "P")))
        XCTAssertEqual(h.spawns, [1, 2], "a new process reads the account again")
        XCTAssertFalse(h.doubleFinish)
    }

    func testStartBringsTheProcessUpWithoutSigningIn() {
        var h = Harness()
        h.handle(.start); h.handshake(account: nil)
        XCTAssertEqual(h.session.process, .ready); XCTAssertEqual(h.session.account, .signedOut)
        XCTAssertFalse(h.methods.contains("account/login/start"), "starting never opens a sign-in page")
        XCTAssertFalse(h.effects.contains { if case .open = $0 { return true }; return false })
    }

    func testIdleLetsTheProcessGoOnlyWhenNothingIsWanted() {
        var h = Harness(); let id = h.running()
        h.handle(.idle); XCTAssertEqual(h.kills, 0, "a request is in flight")
        h.complete(); _ = id
        h.handle(.idle); XCTAssertEqual(h.kills, 1); XCTAssertEqual(h.session.process, .down)
        XCTAssertTrue(h.session.handle(.exited(spawn: 1, reason: nil)).isEmpty, "the exit that follows is not a failure")
    }

    // MARK: The model's environment, in random order

    /// A server and its pipe, as in the TLA+ module: FIFO both ways, replies in order, and at any
    /// moment it may emit a delta, use a tool, finish the turn, or die.
    private struct World {
        var harness = Harness()
        var random: Random
        var alive = false, spawn = 0
        var toServer: [[String: Any]] = [], toClient: [[String: Any]] = []
        var sentSeen = 0
        var checkOK = false, checkAnswered = false
        var threads: [String: (state: String, turn: String, tooled: Bool, deltas: Int)] = [:]
        var nextThread = 0
        var requested: [UUID] = []
        var threadOf: [UUID: String] = [:]
        var prompts: [String: UUID] = [:]
        var violations: [String] = []
        var allowBadCheck: Bool

        mutating func step(_ event: CodexSession.Event) {
            let effects = harness.handle(event)
            for effect in effects {
                switch effect {
                case .spawn(let number): spawn = number; alive = true; toServer = []; toClient = []; threads = [:]; checkOK = false; checkAnswered = false
                case .kill: alive = false; toServer = []; toClient = []
                case .send:
                    if case .unsafe = harness.session.process { violations.append("wrote after unsafe") }
                default: break
                }
            }
            // What the reducer wrote reaches the pipe, in order, unless the process is gone.
            while sentSeen < harness.sent.count {
                let message = harness.sent[sentSeen]; sentSeen += 1
                if message["method"] as? String == "turn/start" {
                    if !(checkAnswered && checkOK) { violations.append("prompt before the check passed") }
                    if case .ready = harness.session.process {} else { violations.append("prompt while not ready") }
                }
                if alive { toServer.append(message) }
            }
            if harness.doubleFinish { violations.append("a caller was finished twice") }
            if case .unsafe = harness.session.process, harness.session.active != 0 { violations.append("unsafe with callers still waiting") }
            if harness.session.process == .down, harness.session.active != 0 { violations.append("down with callers still waiting") }
            for (id, result) in harness.finished {
                if case .success = result, let thread = threadOf[id], tooledThreads.contains(thread) { violations.append("text from a turn that used a tool") }
            }
        }
        var tooledThreads: Set<String> = []

        mutating func serverReads() {
            guard alive, !toServer.isEmpty else { return }
            let message = toServer.removeFirst()
            guard let id = message["id"], let method = message["method"] as? String else { return }
            let parameters = message["params"] as? [String: Any] ?? [:]
            switch method {
            case "initialize": toClient.append(["id": id, "result": [:]])
            case "mcpServerStatus/list":
                checkOK = !(allowBadCheck && random.chance(8)); checkAnswered = true
                toClient.append(["id": id, "result": ["data": checkOK ? [] : [["name": "leaked"]]]])
            case "account/read":
                toClient.append(["id": id, "result": ["account": ["type": "chatgpt", "email": "a@b.c", "planType": "pro"], "requiresOpenaiAuth": true]])
            case "thread/start":
                nextThread += 1; let thread = "T\(spawn)-\(nextThread)"
                threads[thread] = ("idle", "", false, 0)
                toClient.append(["id": id, "result": ["thread": ["id": thread], "model": "m", "approvalPolicy": "never",
                                                      "sandbox": ["type": "readOnly", "networkAccess": false], "instructionSources": []]])
            case "turn/start":
                guard let thread = parameters["threadId"] as? String else { return }
                let prompt = ((parameters["input"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
                if let caller = prompts[prompt] { threadOf[caller] = thread }
                threads[thread] = ("active", "U-" + thread, false, 0)
                toClient.append(["id": id, "result": ["turn": ["id": "U-" + thread]]])
            case "turn/interrupt":
                guard let thread = parameters["threadId"] as? String, threads[thread]?.state == "active" else { return }
                threads[thread]?.state = "done"
                toClient.append(["method": "turn/completed", "params": ["threadId": thread, "turn": ["id": "U-" + thread, "status": "interrupted"]]])
            default: toClient.append(["id": id, "result": [:]])
            }
        }
        mutating func serverActs() {
            guard alive, let thread = threads.filter({ $0.value.state == "active" }).keys.sorted().randomElement(using: &random) else { return }
            switch random.below(6) {
            case 0, 1 where threads[thread]!.deltas < 3:
                threads[thread]!.deltas += 1
                toClient.append(["method": "item/agentMessage/delta", "params": ["threadId": thread, "turnId": "U-" + thread, "itemId": "I", "delta": "word "]])
            case 2 where !threads[thread]!.tooled:
                threads[thread]!.tooled = true; tooledThreads.insert(thread)
                if random.chance(2) { toClient.append(["method": "item/started", "params": ["threadId": thread, "turnId": "U-" + thread, "item": ["type": "mcpToolCall", "id": "X"]]]) }
                else { toClient.append(["id": 9_000 + random.below(100), "method": "item/tool/requestUserInput", "params": ["threadId": thread]]) }
            case 3, 4:
                threads[thread]!.state = "done"
                let status = random.chance(4) ? "failed" : "completed"
                toClient.append(["method": "turn/completed", "params": ["threadId": thread, "turn": ["id": "U-" + thread, "status": status]]])
            default: break
            }
        }
        mutating func crash() { guard alive else { return }; alive = false; toServer = []; toClient.append(["__eof": true]) }
        mutating func clientReads() {
            guard !toClient.isEmpty else { return }
            let message = toClient.removeFirst()
            if message["__eof"] != nil { step(.exited(spawn: spawn, reason: nil)) }
            else { step(.received(spawn: spawn, try! JSONSerialization.data(withJSONObject: message))) }
        }
    }

    private struct Random: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 11 ^ state }
        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
        mutating func chance(_ oneIn: Int) -> Bool { below(oneIn) == 0 }
    }

    func testRandomOrdersKeepTheModelsProperties() {
        var texts = 0, unsafeRuns = 0, cancelled = 0, restarts = 0
        for seed in 1...4_000 {
            var world = World(random: Random(state: UInt64(seed) &* 0x9E3779B97F4A7C15), allowBadCheck: seed % 5 == 0)
            let callers = (0..<(1 + seed % 3)).map { _ in UUID() }
            var asked: Set<UUID> = []
            // Mostly the ordinary exchange, with the disruptions (cancel, timeout, crash, a stuck
            // handshake) rare enough that turns also complete.
            for _ in 0..<(120 + seed % 80) {
                switch world.random.below(40) {
                case 0...3:
                    if let id = callers.first(where: { !asked.contains($0) }) {
                        asked.insert(id); world.requested.append(id)
                        let prompt = "PROMPT-\(id.uuidString)"; world.prompts[prompt] = id
                        world.step(.generate(id: id, CodexRequest(prompt: prompt)))
                    }
                case 4:
                    guard world.random.chance(2), let id = callers.randomElement(using: &world.random) else { break }
                    world.step(.cancel(id: id))
                    // A cancel that came first must still be answered when the request arrives.
                    if !asked.contains(id) { asked.insert(id); world.requested.append(id); world.step(.generate(id: id, CodexRequest(prompt: "X"))) }
                case 5: if world.random.chance(4), let id = world.requested.randomElement(using: &world.random) { world.step(.timeout(id: id)) }
                case 6: if world.random.chance(6) { world.crash() } else if world.random.chance(25) { world.step(.disconnect) }
                case 7: if world.random.chance(8) { world.step(.handshakeTimeout(spawn: world.spawn)) }
                case 8...19: world.serverReads()
                case 20...27: world.serverActs()
                default: world.clientReads()
                }
                if !world.violations.isEmpty { break }
            }
            // The model's liveness property, with its fairness: the client reads what is there, and
            // the two timeouts fire for whatever is still silent. Then nobody may be left waiting.
            for _ in 0..<400 where world.harness.session.active > 0 || !world.toClient.isEmpty {
                if !world.toClient.isEmpty { world.clientReads(); continue }
                if world.harness.session.process == .starting || world.harness.session.process == .checking {
                    world.step(.handshakeTimeout(spawn: world.spawn)); continue
                }
                for id in world.requested { world.step(.timeout(id: id)) }
            }
            XCTAssertEqual(world.violations, [], "seed \(seed)")
            XCTAssertEqual(world.harness.session.active, 0, "seed \(seed): a caller never finished")
            XCTAssertEqual(Set(world.harness.finished.keys), Set(world.requested), "seed \(seed): every request ends exactly once")
            if !world.violations.isEmpty { return }
            texts += world.harness.finished.values.filter { (try? $0.get()) != nil }.count
            cancelled += world.harness.finished.values.filter { self.failure($0) == .cancelled }.count
            if case .unsafe = world.harness.session.process { unsafeRuns += 1 }
            restarts += max(0, world.harness.spawns.count - 1)
        }
        // The runs must actually reach the cases the properties are about.
        XCTAssertGreaterThan(texts, 500); XCTAssertGreaterThan(unsafeRuns, 200)
        XCTAssertGreaterThan(cancelled, 300); XCTAssertGreaterThan(restarts, 200)
    }
}
