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
