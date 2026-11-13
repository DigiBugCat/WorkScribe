import AppKit
import Foundation
import WorkScribeCore

/// Where Codex lives for WorkScribe, and how it is started.
///
/// WorkScribe gives Codex a home of its own (`CODEX_HOME`), separate from `~/.codex`. A thread
/// started from someone's everyday Codex home carries their tool servers, plugins, instruction
/// files and a shell; meeting text must never be put in front of those. A home that only
/// WorkScribe writes to has none, the flags below switch off every tool Codex ships with, and
/// `CodexSession` refuses to use a connection that shows one anyway.
///
/// The sign-in is shared, not the home: when nobody has signed in here, the home's `auth.json` is a
/// link to the everyday Codex home's, so someone already signed in to Codex has nothing to do.
/// Codex writes that file in place (checked against 0.162.1 with a scratch home: the link and its
/// target's inode survive a credentials write), so both homes always see the same sign-in, exactly as
/// two Codex windows sharing one home do.
enum CodexInstall {
    static var home: URL {
        ProcessInfo.processInfo.environment["WORKSCRIBE_CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WorkScribe/Codex")
    }
    /// The threads' working directory: empty, so there is nothing in it to read.
    static var workspace: URL { home.appendingPathComponent("workspace", isDirectory: true) }

    /// `WORKSCRIBE_CODEX`, then the "codexPath" setting, then the usual install locations.
    static func executable(fileManager: FileManager = .default) -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let candidates = [
            ProcessInfo.processInfo.environment["WORKSCRIBE_CODEX"], UserDefaults.standard.string(forKey: "codexPath"),
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex", home + "/.local/bin/codex", home + "/.npm-global/bin/codex",
            home + "/.bun/bin/codex", "/Applications/Codex.app/Contents/Resources/codex",
        ]
        return candidates.compactMap { $0 }.filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    /// Features that give a thread a tool, a plugin, memory of earlier threads, or a second agent.
    ///
    /// Checked against Codex 0.162.1 in WorkScribe's home (`WorkScribe --verify-codex` repeats it): with
    /// these off a thread has no shell and no sub-agents; the `exec` definition that remains answers
    /// "code-mode host is disabled" and `request_user_input` "unavailable", without running anything.
    /// `--strict-config` makes Codex refuse to start on a setting it does not know, and it refuses an
    /// unknown feature name by itself, so a future Codex that renames one of these fails loudly here
    /// instead of quietly running with more than this list allows.
    static let disabledFeatures = [
        "shell_tool", "unified_exec", "apps", "plugins", "remote_plugin", "plugin_sharing", "hooks", "memories",
        "multi_agent", "multi_agent_v2", "skill_search", "skill_mcp_dependency_install", "tool_suggest", "sleep_tool",
        "view_image", "image_generation", "browser_use", "browser_use_external", "computer_use", "in_app_browser",
        "goals", "code_mode_host", "workspace_dependencies", "chronicle", "realtime_conversation",
    ]
    static var arguments: [String] {
        ["app-server", "--strict-config"] + disabledFeatures.flatMap { ["--disable", $0] }
            + ["-c", "web_search=\"disabled\"", "-c", "project_doc_max_bytes=0", "-c", "agents.enabled=false"]
    }

    /// The home Codex uses when nobody tells it otherwise: where the person is already signed in.
    static var everydayHome: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex") }
    static var credentials: URL { home.appendingPathComponent("auth.json") }
    /// Left by "Disconnect": do not link the everyday sign-in again until the person asks.
    private static var disconnected: URL { home.appendingPathComponent("workscribe-disconnected") }

    /// Makes the home and, when it has no sign-in of its own, borrows the everyday one.
    static func prepare() {
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        linkSignIn()
    }

    /// Points this home's credentials at the everyday Codex sign-in. False when there is nothing to
    /// borrow, this home already has credentials (its own, or the link), or the person disconnected.
    @discardableResult static func linkSignIn() -> Bool {
        let files = FileManager.default
        let source = everydayHome.appendingPathComponent("auth.json")
        // `attributesOfItem` sees a link whose target is gone; `fileExists` would not.
        guard (try? files.attributesOfItem(atPath: credentials.path)) == nil, !files.fileExists(atPath: disconnected.path),
              files.fileExists(atPath: source.path), everydayHome.standardizedFileURL != home.standardizedFileURL else { return false }
        return (try? files.createSymbolicLink(at: credentials, withDestinationURL: source)) != nil
    }

    /// This home's sign-in is the everyday Codex one, not one made in WorkScribe.
    static var usesEverydaySignIn: Bool { (try? FileManager.default.destinationOfSymbolicLink(atPath: credentials.path)) != nil }

    /// Stops borrowing the everyday sign-in. The everyday Codex stays signed in: only the link goes.
    static func unlinkSignIn() {
        guard usesEverydaySignIn else { return }
        try? FileManager.default.removeItem(at: credentials)
        FileManager.default.createFile(atPath: disconnected.path, contents: nil)
    }
    static func allowLinking() { try? FileManager.default.removeItem(at: disconnected) }

    /// There is a sign-in to try. Enough to say "probably usable" before the first start.
    static var hasCredentials: Bool { prepare(); return FileManager.default.fileExists(atPath: credentials.path) }
}

extension Notification.Name {
    /// The Codex connection or account changed. Read `CodexStatus.current`.
    static let workScribeCodexChanged = Notification.Name("WorkScribeCodexChanged")
}

/// What the rest of the app may know about Codex without waiting for it.
struct CodexStatus: Equatable, Sendable {
    var installed = CodexInstall.executable() != nil
    var process = CodexSession.Process.down
    var account = CodexAccount.unknown
    /// The model the last thread ran on.
    var model: String?
    var failure: String?

    /// Worth asking for text.
    var usable: Bool {
        guard installed else { return false }
        if case .unsafe = process { return false }
        switch account {
        case .signedIn: return true
        case .unknown: return CodexInstall.hasCredentials
        case .signedOut, .signingIn: return false
        }
    }
    /// For the plugin's engine status: "ready", "loading" or "missing".
    var engineState: String {
        guard usable else { return "missing" }
        return process == .starting || process == .checking ? "loading" : "ready"
    }
    /// One line for Settings.
    var summary: String {
        guard installed else { return "Codex isn’t installed. Install it (brew install --cask codex) to get AI lines, titles and answers." }
        if case .unsafe(let why) = process { return "Stopped using Codex: \(why)." }
        switch account {
        case .signedIn(let email, let plan):
            return "Signed in" + (email.map { " as \($0)" } ?? "") + (plan.map { " · \($0)" } ?? "")
                + (CodexInstall.usesEverydaySignIn ? " · using your Codex sign-in" : "")
        case .signingIn: return "Finish signing in in your browser…"
        case .signedOut: return "Not signed in. AI lines, titles and answers are off."
        case .unknown: return CodexInstall.hasCredentials ? "Signed in" : "Not signed in. AI lines, titles and answers are off."
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var value = CodexStatus()
    static var current: CodexStatus { lock.withLock { value } }
    static func update(_ change: (inout CodexStatus) -> Void) {
        let changed: Bool = lock.withLock { let before = value; change(&value); return before != value }
        guard changed else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .workScribeCodexChanged, object: nil)
            NotificationCenter.default.post(name: .workScribeTextModelState, object: nil, userInfo: ["state": current.engineState])
        }
    }
}

/// Runs `codex app-server` and performs what `CodexSession` decides. All protocol decisions are in
/// the session; this actor only owns the process, the pipes, the clock and the callers waiting.
actor CodexAppServer {
    static let shared = CodexAppServer()

    struct Timing: Sendable {
        /// The process must answer `initialize` and the checks within this.
        var handshake: Duration = .seconds(20)
        /// A request fails when the whole connection has been silent this long.
        var stall: Duration = .seconds(45)
        /// A request fails after this long whatever happens.
        var limit: Duration = .seconds(240)
        /// The process is let go after this long with nothing to do.
        var idle: Duration = .seconds(300)
        var tick: Duration = .seconds(1)
    }

    private struct Caller {
        let continuation: CheckedContinuation<CodexReply, Error>
        let onDelta: (@Sendable (String) -> Void)?
        let started: ContinuousClock.Instant
    }
    private final class Running {
        let process: Process
        let input: FileHandle
        let writer = DispatchQueue(label: "WorkScribe.codex.write")
        init(process: Process, input: FileHandle) { self.process = process; self.input = input }
    }

    private var session: CodexSession
    private let timing: Timing
    /// This is the app's own connection (WorkScribe's Codex home), not one a test pointed elsewhere.
    private let usesInstall: Bool
    private let executable: @Sendable () -> URL?
    private let arguments: [String]
    private let environment: [String: String]
    private let open: @Sendable (String) -> Void
    private var running: Running?
    private var complaint: Complaint?
    private var callers: [UUID: Caller] = [:]
    private var buffers: [Int: Data] = [:]
    private var spawnedAt: ContinuousClock.Instant?
    private var lastLine = ContinuousClock.now
    private var idleSince: ContinuousClock.Instant?
    private var ticker: Task<Void, Never>?

    init(settings: CodexSession.Settings? = nil, timing: Timing = Timing(),
         executable: @escaping @Sendable () -> URL? = { CodexInstall.executable() },
         arguments: [String] = CodexInstall.arguments,
         environment: [String: String]? = nil,
         open: @escaping @Sendable (String) -> Void = { url in
             guard let url = URL(string: url) else { return }
             DispatchQueue.main.async { NSWorkspace.shared.open(url) }
         }) {
        let model = UserDefaults.standard.string(forKey: "codexModel").flatMap { $0.isEmpty ? nil : $0 }
        let effort = UserDefaults.standard.string(forKey: "codexEffort").flatMap { $0.isEmpty ? nil : $0 } ?? "low"
        session = CodexSession(settings: settings ?? .init(model: model, effort: effort, workspace: CodexInstall.workspace.path))
        self.timing = timing; self.executable = executable; self.arguments = arguments
        usesInstall = environment == nil
        self.environment = environment ?? ["CODEX_HOME": CodexInstall.home.path]; self.open = open
        signal(SIGPIPE, SIG_IGN)
    }

    // MARK: What callers use

    /// Writes one piece of text. `onDelta` receives it as it arrives. Cancelling the task stops the turn.
    func generate(_ request: CodexRequest, onDelta: (@Sendable (String) -> Void)? = nil) async throws -> CodexReply {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                callers[id] = Caller(continuation: continuation, onDelta: onDelta, started: .now)
                apply(.generate(id: id, request))
            }
        } onCancel: { Task { await self.apply(.cancel(id: id)) } }
    }

    /// Starts the process ahead of the first request, so that request does not pay for the start. Also how
    /// Settings learns who is signed in. Never opens a sign-in page.
    func start() {
        guard executable() != nil else { CodexStatus.update { $0.installed = false }; return }
        apply(.start)
    }
    /// Uses the everyday Codex sign-in when there is one; otherwise opens the ChatGPT sign-in page.
    func signIn() {
        CodexInstall.allowLinking()
        if usesInstall, CodexInstall.linkSignIn() { apply(.disconnect); apply(.start) } else { apply(.signIn) }
    }
    func cancelSignIn() { apply(.cancelSignIn) }
    /// A borrowed sign-in is let go of, leaving the everyday Codex signed in. One made here is signed out.
    func signOut() {
        if usesInstall, CodexInstall.usesEverydaySignIn { CodexInstall.unlinkSignIn(); apply(.disconnect) } else { apply(.signOut) }
    }
    /// Forget an "unsafe" verdict and try again.
    func reset() { apply(.reset); CodexStatus.update { $0.failure = nil } }
    func shutdown() { idleSince = nil; apply(.idle) }
    func setModel(_ model: String?, effort: String) { session.settings.model = model; session.settings.effort = effort }
    var state: (process: CodexSession.Process, account: CodexAccount) { (session.process, session.account) }

    // MARK: Session

    private func apply(_ event: CodexSession.Event) {
        for effect in session.handle(event) { perform(effect) }
        if session.isIdle { if idleSince == nil { idleSince = .now } } else { idleSince = nil }
        keepTime()
    }

    private func perform(_ effect: CodexSession.Effect) {
        switch effect {
        case .spawn(let number): launch(number)
        case .send(let line):
            guard let running else { return }
            let handle = running.input
            running.writer.async { try? handle.write(contentsOf: line + Data([0x0A])) }
        case .kill:
            running?.process.terminate(); running = nil
        case .delta(let id, let text):
            callers[id]?.onDelta?(text)
        case .finish(let id, let result):
            guard let caller = callers.removeValue(forKey: id) else { return }
            switch result {
            case .success(let reply):
                if let model = reply.model { CodexStatus.update { $0.model = model } }
                caller.continuation.resume(returning: reply)
            case .failure(.cancelled): caller.continuation.resume(throwing: CancellationError())
            case .failure(let failure): caller.continuation.resume(throwing: failure)
            }
        case .account(let account): CodexStatus.update { $0.account = account }
        case .open(let url): open(url)
        case .status(let process):
            CodexStatus.update {
                $0.process = process
                if case .unsafe(let why) = process { $0.failure = why }
            }
        }
    }

    private func launch(_ number: Int) {
        running?.process.terminate(); running = nil
        spawnedAt = .now; lastLine = .now
        if usesInstall { CodexInstall.prepare() }
        guard let executable = executable() else {
            CodexStatus.update { $0.installed = false }
            fail(number, "it isn’t installed"); return
        }
        CodexStatus.update { $0.installed = true }
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        // Codex's own log is not kept. Only a line saying why it would not start is.
        let complaint = Complaint()
        self.complaint = complaint
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { complaint.read(data) }
        }
        if let home = environment["CODEX_HOME"] {
            let workspace = URL(fileURLWithPath: home).appendingPathComponent("workspace", isDirectory: true)
            try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            process.currentDirectoryURL = workspace
        }
        // One reader, one consumer: lines reach the session in the order the process wrote them,
        // and the end of output arrives after the last line.
        let (chunks, feed) = AsyncStream<Data>.makeStream()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; feed.finish() } else { feed.yield(data) }
        }
        do { try process.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil; feed.finish()
            fail(number, error.localizedDescription); return
        }
        running = Running(process: process, input: input.fileHandleForWriting)
        Task { [weak self] in
            for await chunk in chunks { await self?.ingest(number, chunk) }
            await self?.ended(number)
        }
    }

    /// The process never ran. Reported like an exit, but not from inside `perform`.
    private func fail(_ number: Int, _ reason: String) {
        Task { self.apply(.exited(spawn: number, reason: reason)) }
    }

    private func ingest(_ number: Int, _ chunk: Data) {
        guard number == session.spawn else { return }
        lastLine = .now
        var buffer = (buffers[number] ?? Data()) + chunk
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            if !line.isEmpty { apply(.received(spawn: number, Data(line))) }
        }
        buffers[number] = Data(buffer)
    }

    private func ended(_ number: Int) {
        buffers[number] = nil
        guard number == session.spawn else { return }
        running = nil
        apply(.exited(spawn: number, reason: complaint?.line))
    }

    /// The last line Codex printed that starts with "Error:", e.g. "Error: Unknown feature flag: x".
    private final class Complaint: @unchecked Sendable {
        private let lock = NSLock()
        private var found: String?
        func read(_ data: Data) {
            let text = String(decoding: data, as: UTF8.self)
            guard let line = text.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("Error:") }) else { return }
            lock.withLock { found = "Codex would not start. " + String(line.prefix(200)) }
        }
        var line: String? { lock.withLock { found } }
    }

    // MARK: Time

    /// One clock for everything the session cannot see: a silent handshake, a silent turn, idleness.
    private func keepTime() {
        let needed = !callers.isEmpty || session.process == .starting || session.process == .checking || idleSince != nil && running != nil
        guard needed else { ticker?.cancel(); ticker = nil; return }
        guard ticker == nil else { return }
        let tick = timing.tick
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tick)
                guard let self, !Task.isCancelled else { return }
                await self.tick()
            }
        }
    }

    private func tick() {
        let now = ContinuousClock.now
        if session.process == .starting || session.process == .checking, let spawnedAt, now - spawnedAt >= timing.handshake {
            apply(.handshakeTimeout(spawn: session.spawn))
        }
        for (id, caller) in callers {
            let quietSince = max(caller.started, lastLine)
            if now - quietSince >= timing.stall || now - caller.started >= timing.limit { apply(.timeout(id: id)) }
        }
        if let idleSince, now - idleSince >= timing.idle { self.idleSince = nil; apply(.idle) }
        keepTime()
    }
}
