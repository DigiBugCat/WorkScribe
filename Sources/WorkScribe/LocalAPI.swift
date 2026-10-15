import AVFoundation
import Combine
import Foundation
import WorkScribeCore

/// Request handling for the local API, on the main actor next to the app model. See docs/api/local-api.md.
@MainActor
final class LocalAPI {
    let model: AppModel
    let ask: AskService
    let hub: EventHub
    private(set) var server: LocalAPIServer?
    /// The meeting's note in the vault and its Obsidian link (VaultHookup), for meeting JSON.
    var vaultPath: (String) -> String? = { VaultHookup.shared?.noteURL(for: $0)?.path }
    var obsidianLink: (String) -> String? = { VaultHookup.shared?.obsidianURL(for: $0)?.absoluteString }

    init(model: AppModel, ask: AskService) {
        self.model = model; self.ask = ask
        hub = EventHub(model: model, ask: ask)
        hub.status = { [weak self] in self?.status() }
    }

    /// Starts listening and writes api.json. Returns the port.
    @discardableResult
    func start(configURL: URL = APIConfig.defaultURL) async throws -> UInt16 {
        let server = LocalAPIServer { [weak self] request, connection in
            Task { @MainActor in self?.handle(request, connection) }
        }
        let port = try await server.start()
        try APIConfig(port: Int(port), token: server.token).write(to: configURL)
        self.server = server
        return port
    }

    func stop() { server?.stop(); server = nil }

    // MARK: Routing

    func handle(_ request: HTTPRequest, _ connection: APIConnection) {
        let cors = APIGuard.cors(request)
        func reply(_ response: HTTPResponse) {
            var response = response
            response.headers.merge(cors) { $1 }
            connection.send(response)
        }
        switch APIRoute.match(method: request.method, path: request.path) {
        case .failure(let error):
            reply(.error(error.status, error == .notFound ? "No such endpoint" : "Method not allowed"))
        case .success(.events):
            hub.subscribe(connection, cors: cors)
        case .success(.ask):
            guard let body = decode(APIAskBody.self, request, reply) else { return }
            streamAnswer(body, connection, cors: cors, reply: reply)
        case .success(let route):
            Task { reply(await respond(route, request)) }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ request: HTTPRequest, _ reply: (HTTPResponse) -> Void) -> T? {
        do { return try APIJSON.decoder.decode(T.self, from: request.body.isEmpty ? Data("{}".utf8) : request.body) }
        catch { reply(.error(400, "Invalid JSON body: \(error.localizedDescription)")); return nil }
    }

    private func body<T: Decodable>(_ type: T.Type, _ request: HTTPRequest) throws -> T {
        do { return try APIJSON.decoder.decode(T.self, from: request.body.isEmpty ? Data("{}".utf8) : request.body) }
        catch { throw APIFailure(400, "Invalid JSON body: \(error.localizedDescription)") }
    }

    struct APIFailure: Error { let status: Int; let message: String; init(_ status: Int, _ message: String) { self.status = status; self.message = message } }

    func respond(_ route: APIRoute, _ request: HTTPRequest) async -> HTTPResponse {
        do {
            switch route {
            case .status:
                return .json(status())
            case .startRecording:
                let start = try body(APIStartBody.self, request)
                guard !model.busy else { throw APIFailure(409, model.phase == "recording" ? "Already recording" : "Recording is \(model.phase)") }
                guard model.speechReady || model.phase == "error" else { throw APIFailure(503, "Speech engine is still warming up") }
                await model.start()
                if let title = start.title, let id = model.meeting?.id, model.phase == "recording" { model.rename(id: id, to: title) }
                return .json(status())
            case .resumeRecording(let id):
                guard (!model.busy || (model.phase == "finalizing" && model.finalizationProgress >= 0.35 && model.meeting?.id == id)), let meeting = model.meetingSnapshot(id), meeting.canResume() else { throw APIFailure(409, "Resume is available for ten minutes after stopping, before finalizing") }
                await model.start(resuming: id)
                return .json(status())
            case .stopRecording:
                guard model.phase == "recording" || model.phase == "finalizing" else { throw APIFailure(409, "Not recording") }
                await model.stop()
                return .json(status())
            case .meetings:
                let limit = request.query["limit"].flatMap(Int.init).map { max(1, min($0, 500)) } ?? 50
                var meetings = model.library
                if let live = model.meeting, model.busy, !meetings.contains(where: { $0.id == live.id }) { meetings.insert(live, at: 0) }
                return .json(meetings.prefix(limit).map { APIShapes.summary(model.meeting?.id == $0.id ? model.meeting! : $0, vaultPath: vaultPath($0.id),
                                                                            obsidianLink: obsidianLink($0.id)) })
            case .meeting(let id):
                guard let meeting = model.meetingSnapshot(id) else { throw APIFailure(404, "No such meeting") }
                ask.loadMeetingAttachments(id)
                return .json(APIShapes.detail(meeting, conversations: ask.conversations, attachments: ask.attachments(.meeting(id)),
                                              vaultPath: vaultPath(id), obsidianLink: obsidianLink(id),
                                              clips: VaultHookup.shared?.clips(for: id) ?? [],
                                              blockIDs: VaultHookup.shared?.store.blockIDs(forMeeting: id) ?? [:]))
            case .grabMoment(let id):
                guard model.phase == "recording", model.meeting?.id == id,
                      let recorder = model.screenRecorder else { throw APIFailure(409, "Screen awareness is not recording this meeting") }
                do { return .json(try await Task.detached(priority: .utility) { try recorder.grabMoment() }.value) }
                catch { throw APIFailure(409, error.localizedDescription) }
            case .openDocument(let id):
                guard let meeting = model.meetingSnapshot(id) else { throw APIFailure(404, "No such meeting") }
                guard meeting.retention != "purged", meeting.retention != "purging" else { throw APIFailure(409, "Meeting raw data was deleted") }
                guard let vault = model.retentionService?.vault else { throw APIFailure(503, "Vault is starting") }
                let document = try vault.openDocument(meeting)
                try model.mutateMeeting(id) { $0.document = document; $0.vaultPath = document.path }
                return .json(document)
            case .syncDocument(let id):
                var document = try body(NoteDocument.self, request)
                document.path = FileIdentity.path(document.path)
                try document.validate()
                guard let meeting = model.meetingSnapshot(id), let old = meeting.document else { throw APIFailure(404, "Open the meeting note first") }
                let undoFinalize = old.finalized == true && document.source == old.source && meeting.retention == "finalized"
                    && (meeting.purgeAt ?? .distantPast) > Date()
                    && (try? String(contentsOfFile: document.path, encoding: .utf8)) == document.source
                guard (old.finalized != true || undoFinalize), document.revision == old.revision, document.finalized != true else { throw APIFailure(409, "Stale or finalized document") }
                guard let vault = model.retentionService?.vault else { throw APIFailure(503, "Vault is starting") }
                try vault.validateDocumentPath(document, meetingID: id)
                var next = document; next.revision += 1
                let notes = document.notes(previous: meeting.notes ?? [])
                // Preserve the server's first-typed timestamps in the ledger too.
                for i in next.blocks.indices {
                    next.blocks[i].at = notes[i].createdAt
                    next.blocks[i].images = notes[i].images?.map { NoteImage(target:$0.target,path:$0.path) }
                }
                try model.mutateMeeting(id) { $0.document = next; $0.notes = notes; $0.vaultPath = next.path; if undoFinalize { $0.retention = "live" } }
                model.notesChanged(id)
                model.readNoteImages(id)
                NoteEnhancementScheduler.shared.schedule(id, model: model)
                return .json(next)
            case .finalizeDocument(let id):
                guard let meeting = model.meetingSnapshot(id) else { throw APIFailure(404, "No such meeting") }
                guard meeting.endedAt != nil, !model.busy else { throw APIFailure(409, "Stop recording first") }
                guard let retention = model.retentionService else { throw APIFailure(503, "Vault is starting") }
                guard await NoteEnhancementScheduler.shared.finish(id, model: model) else { throw APIFailure(409, "Transcript polish could not finish; saved audio is available for retry") }
                guard model.meetingSnapshot(id)?.endedAt == meeting.endedAt, !model.busy else { throw APIFailure(409, "Recording resumed during the final pass") }
                try await retention.finalize(id)
                return .json(model.meetingSnapshot(id)!.document)
            case .done(let id):
                guard let meeting = model.meetingSnapshot(id) else { throw APIFailure(404, "No such meeting") }
                guard meeting.endedAt != nil, !(model.busy && model.meeting?.id == id) else { throw APIFailure(409, "Stop recording first") }
                guard let retention = model.retentionService else { throw APIFailure(503, "Retention service is starting") }
                try await retention.done(id)
                return .json(APIShapes.summary(model.meetingSnapshot(id)!, vaultPath: vaultPath(id), obsidianLink: obsidianLink(id)))
            case .addNote(let id):
                let note = try body(APINoteBody.self, request)
                guard let meeting = model.meetingSnapshot(id) else { throw APIFailure(404, "No such meeting") }
                guard meeting.document == nil else { throw APIFailure(409, "Edit the meeting document in Obsidian") }
                let added = try model.addNote(meetingID: id, text: note.text, at: note.at, fromAnswer: note.fromAnswer,
                                              fromMissedTopic: note.fromMissedTopic?.topic)
                return .json(APIShapes.note(added, meeting: meeting, chunks: APIShapes.chunkMap(meeting),
                                            blockId: VaultHookup.shared?.store.blockIDs(forMeeting: id)[added.id]), status: 201)
            case .editNote(let id, let noteID):
                let note = try body(APINotePatch.self, request)
                guard let meeting = model.meetingSnapshot(id) else { throw APIFailure(404, "No such meeting") }
                guard meeting.document == nil else { throw APIFailure(409, "Edit the meeting document in Obsidian") }
                do {
                    let edited: Note
                    if let enhanced = note.enhanced {
                        edited = try model.editNoteEnhancement(meetingID: id, noteID: noteID, enhanced: enhanced)
                    } else if note.rewrite == true {
                        edited = try model.letAIRewrite(meetingID: id, noteID: noteID)
                    } else {
                        edited = try model.editNote(meetingID: id, noteID: noteID, text: note.text!)
                    }
                    return .json(APIShapes.note(edited, meeting: meeting, chunks: APIShapes.chunkMap(meeting),
                                                blockId: VaultHookup.shared?.store.blockIDs(forMeeting: id)[edited.id]))
                } catch AppModel.NoteError.noNote { throw APIFailure(404, "No such note") }
            case .search:
                let search = try body(APISearchBody.self, request)
                guard let index = ask.index else { throw APIFailure(503, "Search index unavailable") }
                let kinds = search.kinds.map(APIShapes.searchKinds)
                let requestSpec = SearchRequest(search.query, limit: max(1, min(search.limit ?? 20, 100)), perSource: 3, kinds: kinds)
                var moments = await index.moments(requestSpec, attached: false, keywordsOnly: ask.recording)
                // The live meeting's screen isn't indexed until it's saved.
                if let live = ask.liveMeeting, kinds == nil || kinds!.contains(.screen) {
                    moments = AskService.screenMoments(search.query, meeting: live, moments: model.screenMoments, limit: 3) + moments
                }
                let requested = search.kinds.map { Set($0.map { $0 == "meetingSegment" ? "meeting" : $0 }) }
                return .json(moments.map { APIMoment($0) }.filter { requested == nil || requested!.contains($0.kind) })
            case .attachments:
                let attach = try body(APIAttachBody.self, request)
                guard attach.path != nil || attach.text != nil else { throw APIFailure(422, "Give a path or text") }
                if let path = attach.path {
                    guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { throw APIFailure(422, "No file at path") }
                }
                let owner: AttachmentOwner
                if let meetingID = attach.meetingId {
                    guard model.meetingSnapshot(meetingID) != nil else { throw APIFailure(404, "No such meeting") }
                    ask.loadMeetingAttachments(meetingID)
                    owner = .meeting(meetingID)
                } else {
                    owner = .conversation(ask.ensureConversation(attach.conversationId, origin: "api"))
                }
                let attachment = try await ask.attachNow(path: attach.path, text: attach.text, to: owner)
                return .json(APIAttachmentResult(attachment: attachment, owner: owner.indexRoot.replacingOccurrences(of: AttachmentOwner.rootPrefix, with: ""),
                                                 path: ask.url(attachment, owner: owner)?.path), status: 201)
            case .events, .ask:
                return .error(500, "Streaming route")
            }
        } catch let failure as APIFailure {
            return .error(failure.status, failure.message)
        } catch {
            return .error(422, error.localizedDescription)
        }
    }

    func status() -> APIStatus {
        let recording = model.phase == "recording"
        let live = model.busy ? model.meeting : nil
        let screenOn: Bool = {
            switch model.screenState { case .recording, .starting: return true; default: return false }
        }()
        return APIStatus(
            recording: recording, phase: model.phase, meetingId: live?.id, title: live?.title, startedAt: live?.startedAt,
            elapsed: recording ? (live.map { Date().timeIntervalSince($0.startedAt) } ?? 0) : 0,
            sources: .init(mic: recording, system: recording && model.includeSystemAudio && !model.systemAudioBlocked, screen: recording && screenOn),
            permissions: .init(screenRecording: model.screenAccess, microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized),
            warming: !model.speechReady && model.phase != "error", message: model.message,
            model: .init(provider: ask.generatorProvider, name: ask.generatorModel), finalizationProgress: model.finalizationProgress)
    }

    // MARK: Ask stream

    private func streamAnswer(_ body: APIAskBody, _ connection: APIConnection, cors: [String: String], reply: @escaping (HTTPResponse) -> Void) {
        let question = body.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { reply(.error(422, "Question is empty")); return }
        if let meetingID = body.meetingId, model.meetingSnapshot(meetingID) == nil { reply(.error(404, "No such meeting")); return }
        connection.write(HTTPResponse.eventStreamHead(extra: cors))
        Task {
            let conversationID = ask.ensureConversation(body.conversationId, origin: "api")
            if let meetingID = body.meetingId { ask.setScope(conversationID, meetingID: meetingID) }
            for ref in body.attachments ?? [] {
                if let path = ref.path, !(path.hasPrefix("/") && FileManager.default.fileExists(atPath: path)) { continue }
                _ = try? await ask.attachNow(path: ref.path, text: ref.text, to: .conversation(conversationID))
            }
            var subscription: AnyCancellable?
            var messageID = ""
            subscription = ask.events.sink { event in
                switch event {
                case .trace(_, let id, let trace) where id == messageID:
                    connection.write(SSE.event("trace", trace))
                case .delta(_, let id, let text) where id == messageID:
                    connection.write(SSE.event("token", ["text": text]))
                case .finished(let conversation, let id, _, let message) where id == messageID:
                    if message.state == .failed {
                        connection.write(SSE.event("error", ["message": message.detail ?? message.text]), close: true)
                        subscription?.cancel()
                        return
                    }
                    connection.write(SSE.event("citations", APIAskResult(conversationId: conversation, answer: message.text, state: message.state.rawValue,
                                                                       detail: message.detail, citations: message.citations.map { APIMoment($0.moment, number: $0.number) }, trace: message.trace)))
                    connection.write(SSE.event("done", ["conversationId": conversation]), close: true)
                    subscription?.cancel()
                default: break
                }
            }
            let ids = ask.ask(question, in: conversationID, origin: "api", scopeMeetingID: body.meetingId)
            messageID = ids.message
            connection.write(SSE.event("started", ["conversationId": ids.conversation, "messageId": ids.message]))
            connection.onClose = { [weak ask] in
                Task { @MainActor in subscription?.cancel(); _ = ask }
            }
        }
    }
}

struct APIAskResult: Encodable {
    var conversationId: String
    var answer: String
    var state: String
    var detail: String?
    var citations: [APIMoment]
    var trace: AITrace? = nil
}

/// Server-Sent Events for `GET /v1/events`: status, transcript segments, notes, answers and screen moments.
@MainActor
final class EventHub {
    private var subscribers: [UUID: APIConnection] = [:]
    private var bag: Set<AnyCancellable> = []
    private var sequence = 0
    private var lastStatus: Data?
    private var sentSegments: Set<String> = []
    private var lastPartials: [String: String] = [:]
    private var sentScreen: Set<String> = []
    private var trackedMeeting: String?
    private var answerText: [String: String] = [:]
    private weak var model: AppModel?
    private weak var ask: AskService?
    /// Builds the status payload; set by LocalAPI.
    var status: (() -> APIStatus?)?

    init(model: AppModel, ask: AskService) {
        self.model = model; self.ask = ask
        Publishers.Merge4(model.$phase.map { _ in () }, model.$speechReady.map { _ in () },
                          model.$screenAccess.map { _ in () }, model.$systemAudioBlocked.map { _ in () })
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] in self?.publishStatus() }.store(in: &bag)
        model.$finalizationProgress.map { _ in () }.merge(with: model.$message.map { _ in () })
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.publishStatus() }.store(in: &bag)
        model.$meeting.receive(on: RunLoop.main).sink { [weak self] meeting in self?.transcript(meeting) }.store(in: &bag)
        model.$screenMoments.receive(on: RunLoop.main).sink { [weak self] moments in self?.screen(moments) }.store(in: &bag)
        NotificationCenter.default.publisher(for: .workScribeNotesChanged).receive(on: RunLoop.main)
            .sink { [weak self] note in if let id = note.userInfo?["meeting_id"] as? String { self?.notes(id) } }.store(in: &bag)
        NotificationCenter.default.publisher(for: .workScribeMeetingPurged).receive(on: RunLoop.main)
            .sink { [weak self] note in
                if let id = note.userInfo?["meeting_id"] as? String { self?.publish("meeting.purged", ["meetingId": id]) }
            }.store(in: &bag)
        ask.events.sink { [weak self] event in
            guard let self, let ask = self.ask else { return }
            switch event {
            case .trace(let conversationID, let id, _):
                guard let conversation = ask.conversation(conversationID), let message = conversation.messages.first(where: { $0.id == id }) else { return }
                let question = conversation.messages.prefix { $0.id != id }.last(where: { $0.role == .user })?.text ?? ""
                self.publishAnswer(conversationID, message: message, question: question, text: message.text, done: false)
            case .delta(let conversationID, let id, let text):
                self.answerText[id, default: ""] += text
                guard let conversation = ask.conversation(conversationID),
                      let message = conversation.messages.first(where: { $0.id == id }) else { return }
                let question = conversation.messages.prefix { $0.id != id }.last(where: { $0.role == .user })?.text ?? ""
                self.publishAnswer(conversationID, message: message, question: question, text: self.answerText[id]!, done: false)
            case .finished(let conversationID, let id, let question, let message):
                self.answerText.removeValue(forKey: id)
                self.publishAnswer(conversationID, message: message, question: question, text: message.text, done: true)
            }
        }.store(in: &bag)
        // Browser clips: a `clip` event; "Ask WorkScribe about this page" becomes an `ask_request` for the plugin or
        // quick ask to offer. The page text is untrusted: it is never asked automatically.
        NotificationCenter.default.publisher(for: .workScribeClipReceived).receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let clip = note.userInfo?["clip"] as? SavedClip else { return }
                if note.userInfo?["kind"] as? String == "ask" {
                    self?.publish("ask_request", APIEventAskRequest(clip: clip, question: note.userInfo?["question"] as? String, untrusted: true))
                } else {
                    self?.publish("clip", clip)
                }
            }.store(in: &bag)
        NotificationCenter.default.publisher(for: .workScribeContinueConversation).receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let id = note.userInfo?["conversation_id"] as? String, let conversation = self?.ask?.conversation(id) else { return }
                self?.publish("continue", APIEventContinue(conversationId: id, title: conversation.title, meetingId: conversation.scopeMeetingID,
                                                           markdown: QuickAskView.markdown(conversation)))
            }.store(in: &bag)
        Timer.publish(every: 15, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.keepAlive() }.store(in: &bag)
    }

    private func publishAnswer(_ conversationID: String, message: AskMessage, question: String, text: String, done: Bool) {
        let meetingID = ask?.conversation(conversationID)?.scopeMeetingID
        let start = meetingID.flatMap { model?.meetingSnapshot($0)?.startedAt } ?? message.createdAt
        publish("answer", APIEventAnswer(id: message.id, at: max(0, message.createdAt.timeIntervalSince(start)), done: done,
                                         conversationId: conversationID, meetingId: meetingID, question: question, answer: text,
                                         state: message.state.rawValue, citations: message.citations.map { APIMoment($0.moment, number: $0.number) }, trace: message.trace))
    }

    func subscribe(_ connection: APIConnection, cors: [String: String]) {
        let id = UUID()
        subscribers[id] = connection
        connection.onClose = { [weak self] in Task { @MainActor in self?.subscribers.removeValue(forKey: id) } }
        connection.write(HTTPResponse.eventStreamHead(extra: cors))
        if let status = status?() ?? nil { connection.write(SSE.event("status", status, id: next())) }
    }

    func publish<T: Encodable>(_ name: String, _ value: T) {
        guard !subscribers.isEmpty else { return }
        let data = SSE.event(name, value, id: next())
        for (id, connection) in subscribers {
            if connection.isClosed { subscribers.removeValue(forKey: id) } else { connection.write(data) }
        }
    }

    private func next() -> Int { sequence += 1; return sequence }

    private func keepAlive() {
        for (id, connection) in subscribers {
            if connection.isClosed { subscribers.removeValue(forKey: id) } else { connection.write(SSE.keepAlive) }
        }
        // Elapsed time moves while recording; send it with the keep-alive.
        if model?.phase == "recording" { publishStatus(force: true) }
    }

    private func publishStatus(force: Bool = false) {
        guard let status = status?() ?? nil else { return }
        var comparable = status; comparable.elapsed = 0
        let data = try? APIJSON.encoder.encode(comparable)
        guard force || data != lastStatus else { return }
        lastStatus = data
        publish("status", status)
    }

    private func transcript(_ meeting: Meeting?) {
        guard let meeting, let model, model.busy else { return }
        if trackedMeeting != meeting.id { trackedMeeting = meeting.id; sentSegments = []; lastPartials = [:]; sentScreen = [] }
        for segment in APIShapes.segments(meeting) {
            if segment.final {
                guard sentSegments.insert(segment.id).inserted else { continue }
                publish("transcript", APIEventSegment(meetingId: meeting.id, segment: segment))
            } else if lastPartials[segment.source] != segment.text {
                lastPartials[segment.source] = segment.text
                publish("transcript", APIEventSegment(meetingId: meeting.id, segment: segment))
            }
        }
        for source in lastPartials.keys where meeting.partials[source]?.isEmpty ?? true { lastPartials.removeValue(forKey: source) }
    }

    private func screen(_ moments: [ScreenMoment]) {
        guard let model, let meeting = model.meeting else { return }
        for moment in moments where sentScreen.insert(moment.id + "@\(moment.end)").inserted {
            let thumbnail = model.screenThumbnailURL(moment, meetingID: meeting.id)?.path
            publish("screen", APIEventScreen(meetingId: meeting.id, id: moment.id, start: moment.start, end: moment.end, text: moment.text,
                                             app: moment.app, window: moment.window, thumbnail: thumbnail,
                                             link: WorkScribeLink.meeting(id: meeting.id, seconds: moment.start, segment: nil).url.absoluteString))
        }
    }

    private func notes(_ meetingID: String) {
        guard let meeting = model?.meetingSnapshot(meetingID) else { return }
        let chunks = APIShapes.chunkMap(meeting)
        publish("notes", APIEventNotes(meetingId: meetingID, notes: (meeting.notes ?? []).map { APIShapes.note($0, meeting: meeting, chunks: chunks, blockId: VaultHookup.shared?.store.blockIDs(forMeeting: meetingID)[$0.id]) },
                                       missedTopics: (meeting.missedTopics ?? []).map {
                                           APIMissedTopic(topic: $0.topic, text: $0.text,
                                                          excerpts: APIShapes.excerpts($0.excerptRefs, note: nil, meeting: meeting, chunks: chunks))
                                       },
                                       actionItems: APIShapes.actionItems(meeting), documentFinalized: meeting.document?.finalized))
    }
}

struct APIEventSegment: Encodable { var meetingId: String; var segment: APISegment }
struct APIEventScreen: Encodable {
    var meetingId: String; var id: String; var start: Double; var end: Double; var text: String
    var app: String?; var window: String?; var thumbnail: String?; var link: String
}
struct APIEventNotes: Encodable { var meetingId: String; var notes: [APINote]; var missedTopics: [APIMissedTopic]; var actionItems: [APIActionItem]; var documentFinalized: Bool? = nil }
struct APIEventAnswer: Encodable {
    var id: String; var at: Double; var done: Bool
    var conversationId: String; var meetingId: String?; var question: String; var answer: String; var state: String; var citations: [APIMoment]; var trace: AITrace? = nil
}
struct APIEventContinue: Encodable { var conversationId: String; var title: String; var meetingId: String?; var markdown: String }
struct APIEventAskRequest: Encodable { var clip: SavedClip; var question: String?; var untrusted: Bool }
