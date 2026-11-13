import Foundation
import WorkScribeCore

/// `--verify-api`: starts the local API against a throwaway library, checks the token is required and the Host
/// header is enforced, and prints `GET /v1/status`.
@MainActor
enum APIVerification {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workscribe-api-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: MeetingStore(root: root.appendingPathComponent("Meetings")))
        let ask = AskService(model: model, store: ConversationStore(root: root.appendingPathComponent("Conversations")), generator: nil)
        let api = LocalAPI(model: model, ask: ask)
        let configURL = root.appendingPathComponent("api.json")
        let port = try await api.start(configURL: configURL)
        defer { api.stop() }
        let config = try JSONDecoder().decode(APIConfig.self, from: Data(contentsOf: configURL))
        let mode = (try FileManager.default.attributesOfItem(atPath: configURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        guard config.port == Int(port), mode == 0o600 else { throw CaptureError.message("api.json wrong: port \(config.port), mode \(String(mode, radix: 8))") }

        func get(_ path: String, token: String?, host: String? = nil) async throws -> (Int, Data) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            if let host { request.setValue(host, forHTTPHeaderField: "Host") }
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
        let (unauthorized, _) = try await get("/v1/status", token: nil)
        let (wrongHost, _) = try await get("/v1/status", token: config.token, host: "evil.example")
        let (ok, body) = try await get("/v1/status", token: config.token)
        let (meetings, list) = try await get("/v1/meetings?limit=5", token: config.token)
        guard unauthorized == 401, ok == 200, meetings == 200 else {
            throw CaptureError.message("Unexpected statuses: no token \(unauthorized), status \(ok), meetings \(meetings)")
        }
        FileHandle.standardError.write(Data("port \(port) · no token → \(unauthorized) · foreign Host → \(wrongHost) · meetings → \(String(decoding: list, as: UTF8.self))\n".utf8))

        // Screen history, through the same server: one day with two apps, asked for whole, by app, then deleted.
        func post(_ path: String, _ json: [String: Any] = [:]) async throws -> (Int, Data) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = "POST"; request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
        let today = ScreenDayStore.day(Date())
        var day = ScreenDay(day: today.id, start: today.start)
        day.moments = [ScreenMoment(start: 34_200, end: 34_260, text: "Team plan twelve dollars per seat", app: "Safari", bundleID: "com.apple.Safari", window: "Pricing"),
                       ScreenMoment(start: 36_000, end: 36_100, text: "func start() async throws", app: "Xcode", bundleID: "com.apple.dt.Xcode", window: "AppModel.swift")]
        day.usage = [AppSpan(bundleID: "com.apple.Safari", app: "Safari", category: "Browser", start: 34_200, end: 34_800, windows: ["Pricing"]),
                     AppSpan(bundleID: "com.apple.dt.Xcode", app: "Xcode", category: "Developer tools", start: 36_000, end: 39_600, windows: ["AppModel.swift"])]
        try model.screenDays.save(day)
        let (daysStatus, daysBody) = try await get("/v1/screen/days", token: config.token)
        let days = try APIJSON.decoder.decode(APIScreenDays.self, from: daysBody)
        let (oneStatus, oneBody) = try await get("/v1/screen/days/today?app=safari", token: config.token)
        let one = try APIJSON.decoder.decode(APIScreenDay.self, from: oneBody)
        let (noToken, _) = try await get("/v1/screen/days", token: nil)
        let (missing, _) = try await get("/v1/screen/days/2001-01-01", token: config.token)
        let (traversal, _) = try await get("/v1/screen/days/..%2F..%2Fetc", token: config.token)
        let (pause, _) = try await post("/v1/screen/pause", ["paused": true, "minutes": 1])
        if pause == 200 { _ = try await post("/v1/screen/pause", ["paused": false]) }
        let (deleted, _) = try await post("/v1/screen/days/\(today.id)/delete")
        let (afterDelete, _) = try await get("/v1/screen/days/today", token: config.token)
        guard daysStatus == 200, days.days.map(\.day) == [today.id], days.days.first?.apps.map(\.app) == ["Xcode", "Safari"],
              oneStatus == 200, one.moments.map(\.window) == ["Pricing"], one.moments.first?.link == "workscribe://screen/\(today.id)?t=34200.0",
              noToken == 401, missing == 404, traversal == 404, pause == 200 || pause == 409, deleted == 200, afterDelete == 404 else {
            throw CaptureError.message("Screen history routes: days \(daysStatus) \(days.days.map(\.day)), one \(oneStatus) \(one.moments.map(\.window)), no token \(noToken), missing \(missing), traversal \(traversal), pause \(pause), delete \(deleted), after \(afterDelete)")
        }
        FileHandle.standardError.write(Data("screen history → days \(daysStatus) · by app \(oneStatus) (\(one.moments.count) of \(days.days.first?.moments ?? 0)) · no token \(noToken) · unknown day \(missing) · pause \(pause) · delete \(deleted) then \(afterDelete)\n".utf8))
        FileHandle.standardOutput.write(body)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

extension APIVerification {
    /// Isolated real HTTP handlers for the plugin contract tests. No capture, models, vault or user library.
    static func serveForTests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workscribe-contract-" + UUID().uuidString)
        let store = MeetingStore(root: root.appendingPathComponent("Meetings"))
        var meeting = Meeting(title: "API contract fixture")
        meeting.status = "complete"
        meeting.endedAt = meeting.startedAt.addingTimeInterval(60)
        meeting.segments = [Segment(source: "system", speaker: "system:speaker-1", start: 1, end: 5, text: "Release is Friday.")]
        meeting.missedTopics = [MissedTopic(topic: "Release.", text: "Release is Friday.", excerptRefs: [])]
        try store.save(meeting)
        let model = AppModel(store: store)
        let ask = AskService(model: model, store: ConversationStore(root: root.appendingPathComponent("Conversations")), generator: ContractAnswerGenerator())
        ask.register(ContractMoments(meetingID: meeting.id))
        NoteEnhancementScheduler.shared.enhancer = ContractEnrich()
        NoteEnhancementScheduler.shared.delay = 20_000_000
        NoteEnhancementScheduler.shared.minimumInterval = 0
        let vault = VaultStore(root: root.appendingPathComponent("Notes"), stateDirectory: root.appendingPathComponent("Vault"))
        let index = IndexService(index: try SearchIndex(url: root.appendingPathComponent("index.sqlite")), store: store, embedder: nil)
        ask.index = index
        model.retentionService = MeetingRetention(model: model, ask: ask, vault: vault, index: index)
        let api = LocalAPI(model: model, ask: ask)
        let port = try await api.start(configURL: root.appendingPathComponent("api.json"))
        let config = try JSONDecoder().decode(APIConfig.self, from: Data(contentsOf: root.appendingPathComponent("api.json")))
        let data = try JSONSerialization.data(withJSONObject: ["port": Int(port), "token": config.token, "version": 1,
                                                                "meetingId": meeting.id, "root": root.path])
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        while !Task.isCancelled { try await Task.sleep(nanoseconds: 1_000_000_000) }
        api.stop()
    }
}

private struct ContractMoments: AskMomentProvider {
    let meetingID: String
    func moments(for question: String, context: AskContext) async -> [AskMoment] {
        (1...2).map { AskMoment(id: "fixture-\($0)", sourceKind: "meeting", ref: meetingID, title: "Fixture \($0)",
                               kind: "meetingSegment", start: Double($0), text: "Release is Friday, source \($0).") }
    }
}
private struct ContractAnswerGenerator: AnswerGenerator {
    let displayName = "Contract fixture", provider = "local", modelName = "fixture", isAvailable = true
    func stream(_ prompt: AskPrompt) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("Friday [2]. ")
            continuation.yield("Confirmed [1].")
            continuation.finish()
        }
    }
}
private struct ContractEnrich: Enriching {
    func enhance(_ meeting: Meeting, incremental: Bool) async throws -> Enrichment? {
        var plan = EnrichmentBatch()
        plan.targets = (meeting.notes ?? []).filter { $0.line.owned != true }.map { LineRequest(note: $0, refs: [], fresh: [], previous: nil) }
        try await Task.sleep(nanoseconds: 100_000_000)
        var result = Enrichment(plan: plan)
        for target in plan.targets {
            result.outcomes[target.note.id] = .line(Bullet(topic: "Release", text: "Release is Friday.", refs: []), plan.chunkRefs[target.note.id] ?? [])
            result.bases[target.note.id] = "contract"
        }
        return result
    }
}
