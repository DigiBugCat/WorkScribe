import AppKit
import Combine
import Foundation
import WorkScribeCore

/// What a provider knows about the question being asked.
struct AskContext: Sendable {
    var conversationID: String
    /// The meeting to look in first (live or scoped).
    var scopeMeetingID: String?
    /// A meeting is being recorded: keep work light (the speech engine owns the Neural Engine).
    var recording: Bool
}

/// Extra retrieval for Ask beyond the search index (meetings, folders, attachments). Screen-capture OCR or vault notes
/// that are indexed into `SearchIndex` need nothing here; anything kept elsewhere registers a provider with
/// `AskService.register(_:)`. Moments marked `attached` are prioritized like the conversation's own attachments.
protocol AskMomentProvider: Sendable {
    func moments(for question: String, context: AskContext) async -> [AskMoment]
}

/// Streamed to the local API and the quick-ask panel as answers are written.
enum AskEvent {
    case trace(conversationID: String, messageID: String, trace: AITrace)
    case delta(conversationID: String, messageID: String, text: String)
    /// The finished answer and the question it answers.
    case finished(conversationID: String, messageID: String, question: String, message: AskMessage)
}

/// Chat over meetings and files: retrieval (hybrid search + the live meeting + attachments + providers), a short
/// cited answer from an `AnswerGenerator`, and persistence. Shared by the Ask page and the quick-ask panel.
@MainActor
final class AskService: ObservableObject {
    @Published private(set) var conversations: [Conversation] = []
    /// Conversations whose answer is being written.
    @Published private(set) var working: Set<String> = []
    /// Meeting attachments by meeting ID (loaded on demand).
    @Published private(set) var meetingAttachments: [String: [Attachment]] = [:]
    @Published private(set) var generatorName: String?
    var generatorProvider: String { generator?.provider ?? "none" }
    var generatorModel: String { generator?.modelName ?? "" }

    let store: ConversationStore
    let model: AppModel
    let meetingFiles: MeetingAttachmentStore
    var index: IndexService? { didSet { if index != nil { prune() } } }
    private(set) var providers: [any AskMomentProvider] = []
    private var generator: (any AnswerGenerator)?
    private var tasks: [String: Task<Void, Never>] = [:]
    /// Attachments indexed by words only while recording; embedded once the recording ends.
    private var needsEmbedding: [(URL, AttachmentOwner, String)] = []
    private var phaseObservation: AnyCancellable?
    let events = PassthroughSubject<AskEvent, Never>()

    init(model: AppModel, store: ConversationStore = ConversationStore(), generator: (any AnswerGenerator)? = AnswerGenerators.preferred()) {
        self.model = model; self.store = store; self.generator = generator
        meetingFiles = MeetingAttachmentStore(store: model.store)
        generatorName = generator?.displayName
        conversations = store.list()
        phaseObservation = model.$phase.receive(on: RunLoop.main).sink { [weak self] phase in
            guard let self, phase == "ready" || phase == "error", !needsEmbedding.isEmpty else { return }
            let pending = needsEmbedding; needsEmbedding = []
            for (url, owner, id) in pending { reindex(url, owner: owner, attachmentID: id) }
        }
    }

    func cancelForPurge(_ id: String) {
        for task in tasks.values { task.cancel() }
        tasks.removeAll(); working.removeAll()
        let deleted = Set(conversations.filter { $0.scopeMeetingID == id }.map(\.id))
        needsEmbedding.removeAll { item in
            if item.1 == .meeting(id) { return true }
            if case .conversation(let conversationID) = item.1 { return deleted.contains(conversationID) }
            return false
        }
    }
    func reloadAfterPurge(_ id: String) {
        conversations = store.list(); meetingAttachments.removeValue(forKey: id)
    }

    func register(_ provider: any AskMomentProvider) { providers.append(provider) }

    func setGenerator(_ generator: (any AnswerGenerator)?) {
        self.generator = generator; generatorName = generator?.displayName
    }

    var recording: Bool { model.phase == "recording" || model.phase == "starting" || model.phase == "finalizing" }
    /// The meeting being recorded, if any.
    var liveMeeting: Meeting? { recording ? model.meeting : nil }

    // MARK: Conversations

    func conversation(_ id: String?) -> Conversation? { id.flatMap { id in conversations.first { $0.id == id } } }

    /// A conversation that exists on disk (attachments need a folder before the first question).
    func ensureConversation(_ id: String?, origin: String = "main") -> String {
        if let id, conversation(id) != nil { return id }
        var conversation = Conversation(origin: origin)
        if let live = liveMeeting { conversation.scopeMeetingID = live.id }
        put(conversation)
        return conversation.id
    }

    func togglePin(_ id: String) { update(id) { $0.pinned.toggle() } }
    func rename(_ id: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.title = String(trimmed.prefix(120)) }
    }
    func setScope(_ id: String, meetingID: String?) { update(id) { $0.scopeMeetingID = meetingID } }

    func delete(_ id: String) {
        cancel(id)
        try? store.trash(id)
        conversations.removeAll { $0.id == id }
        if let index { Task { _ = await index.pruneAttachments() } }
    }

    func cancel(_ id: String) { tasks.removeValue(forKey: id)?.cancel(); working.remove(id) }

    private func put(_ conversation: Conversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) { conversations[index] = conversation }
        else { conversations.insert(conversation, at: 0) }
        try? store.save(conversation)
    }

    private func update(_ id: String, save: Bool = true, _ change: (inout Conversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        change(&conversations[index])
        if save { conversations[index].updatedAt = Date(); try? store.save(conversations[index]) }
    }

    private func updateMessage(_ conversationID: String, _ messageID: String, save: Bool = true, _ change: (inout AskMessage) -> Void) {
        update(conversationID, save: save) { conversation in
            if let index = conversation.messages.firstIndex(where: { $0.id == messageID }) { change(&conversation.messages[index]) }
        }
    }

    // MARK: Asking

    /// Adds the question and its answer to `conversationID` (a new conversation when nil). Returns the conversation
    /// and the answer message IDs (follow the answer through `events`).
    @discardableResult
    func ask(_ question: String, in conversationID: String?, origin: String = "main", scopeMeetingID: String? = nil) -> (conversation: String, message: String) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = ensureConversation(conversationID, origin: origin)
        if let scopeMeetingID { update(id) { $0.scopeMeetingID = scopeMeetingID } }
        guard !text.isEmpty else { return (id, "") }
        cancel(id)
        let answerID = UUID().uuidString
        update(id) { conversation in
            if conversation.messages.isEmpty, conversation.title == "New chat" { conversation.title = Conversation.title(for: text) }
            conversation.messages.append(AskMessage(role: .user, text: text))
            conversation.messages.append(AskMessage(id: answerID, role: .assistant, text: "", state: .working))
        }
        working.insert(id)
        tasks[id] = Task { [weak self] in
            await self?.answer(text, conversationID: id, messageID: answerID)
            self?.working.remove(id); self?.tasks.removeValue(forKey: id)
            if let self, let message = conversation(id)?.messages.first(where: { $0.id == answerID }) {
                events.send(.finished(conversationID: id, messageID: answerID, question: text, message: message))
            }
        }
        return (id, answerID)
    }

    private func answer(_ question: String, conversationID: String, messageID: String) async {
        guard let conversation = conversation(conversationID) else { return }
        let started = Date()
        var trace = AITrace()
        trace.steps = [TraceStep("Search notes, transcript and files", status: "running")]
        updateMessage(conversationID, messageID) { $0.trace = trace }
        events.send(.trace(conversationID: conversationID, messageID: messageID, trace: trace))
        defer {
            trace.durationMs = Int(Date().timeIntervalSince(started) * 1000)
            updateMessage(conversationID, messageID) { $0.trace = trace }
        }
        let history = Self.history(conversation.messages.dropLast(2))
        let moments = await retrieve(question, conversation: conversation)
        if Task.isCancelled { return }
        trace.sources = moments.filter { $0.kind == "screen" }.map { TraceSource(kind: $0.kind, title: $0.sourceName, text: $0.snippet ?? $0.text, link: $0.link.url.absoluteString, thumbnail: $0.thumbnail, start: $0.start, end: $0.end) }
        trace.steps = [TraceStep("Searched notes, transcript and files", detail: "\(moments.count) moments found")]
        updateMessage(conversationID, messageID) { $0.trace = trace }
        events.send(.trace(conversationID: conversationID, messageID: messageID, trace: trace))
        guard !moments.isEmpty else {
            updateMessage(conversationID, messageID) {
                $0.state = .empty
                $0.text = "Nothing in your notes or files answers this"
            }
            return
        }
        guard let generator, generator.isAvailable else {
            trace.steps.append(TraceStep("Answer model unavailable", status: "error", detail: "Showing matching sources instead"))
            updateMessage(conversationID, messageID) {
                $0.state = .momentsOnly
                $0.citations = CitationMapper.momentsOnly(moments)
                $0.detail = "No answer model on this Mac, so here are the moments that match."
            }
            return
        }
        trace.model = generator.displayName
        trace.location = generator.provider == "local" ? "On this Mac" : generator.provider
        let prompt = AskPrompt.build(question: question, moments: moments, history: history)
        trace.steps.append(TraceStep("Selected evidence", detail: "\(prompt.moments.count) moments supplied to the model"))
        trace.sources = prompt.moments.map { TraceSource(kind: $0.kind, title: $0.sourceName, text: $0.snippet ?? $0.text, link: $0.link.url.absoluteString, thumbnail: $0.thumbnail, start: $0.start, end: $0.end) }
        trace.steps.append(TraceStep("Writing answer", status: "running", detail: generator.displayName))
        updateMessage(conversationID, messageID) { $0.trace = trace }
        events.send(.trace(conversationID: conversationID, messageID: messageID, trace: trace))
        let provenance = AnswerProvenance()
        var written = ""
        var lastShown = Date.distantPast
        do {
            for try await delta in generator.stream(prompt, provenance: provenance) {
                if Task.isCancelled { break }
                written += delta
                events.send(.delta(conversationID: conversationID, messageID: messageID, text: delta))
                // Redraw a few times a second, not per token.
                if Date().timeIntervalSince(lastShown) > 0.08 {
                    lastShown = Date()
                    let shown = written
                    updateMessage(conversationID, messageID, save: false) { $0.text = shown }
                }
            }
            if Task.isCancelled { return }
            trace.steps.removeAll { $0.status == "running" }
            let used = provenance.snapshot()
            trace.model = used.model; trace.location = "On this Mac"
            trace.steps.append(TraceStep("Wrote answer", detail: used.model))
            let mapped = CitationMapper.map(written, moments: prompt.moments)
            updateMessage(conversationID, messageID) {
                $0.text = mapped.text
                if mapped.citations.isEmpty {
                    $0.citations = CitationMapper.momentsOnly(prompt.moments, limit: 4)
                    $0.state = .momentsOnly
                    $0.detail = "\(generator.displayName) · the moments it read"
                } else {
                    $0.citations = mapped.citations
                    $0.state = .answered
                    $0.detail = trace.model
                }
            }
        } catch {
            if Task.isCancelled { return }
            updateMessage(conversationID, messageID) {
                trace.steps.removeAll { $0.status == "running" }
                trace.steps.append(TraceStep("Couldn’t write answer", status: "error", detail: "Showing matching sources instead"))
                $0.text = written
                $0.state = .momentsOnly
                $0.citations = CitationMapper.momentsOnly(moments)
                $0.detail = "Couldn’t write an answer (\(error.localizedDescription)). Here are the moments that match."
            }
        }
    }

    static func history(_ messages: ArraySlice<AskMessage>) -> [(question: String, answer: String)] {
        var out: [(String, String)] = []
        var question: String?
        for message in messages {
            if message.role == .user { question = message.text }
            else if let asked = question, message.state == .answered { out.append((asked, message.text)); question = nil }
        }
        return out
    }

    /// The conversation's own sources first (live meeting, attachments, the scoped meeting), then everything.
    func retrieve(_ question: String, conversation: Conversation) async -> [AskMoment] {
        let live = liveMeeting
        let scope = conversation.scopeMeetingID
        var priority: [AskMoment] = []
        if let scope, let meeting = model.meetingSnapshot(scope), meeting.retention == "purged",
           let path = meeting.vaultPath, let text = try? String(contentsOfFile: path, encoding: .utf8) {
            priority.append(AskMoment(id: "note:" + scope, sourceKind: "vault", ref: path, title: meeting.title, kind: "document", text: text, attached: true))
        }
        if let live, scope == live.id {
            // What was just said and what's on screen now (LiveContext), then the matching transcript and screen moments.
            let context = model.liveContext(seconds: 120)
            if !context.isEmpty {
                let now = Date().timeIntervalSince(live.startedAt)
                priority.append(AskMoment(id: "live:context", sourceKind: SourceKind.meeting.rawValue, ref: live.id, title: live.title,
                                          kind: ChunkKind.meetingSegment.rawValue, start: max(0, now - 120), end: now,
                                          text: context, snippet: "The last two minutes of the call and the screen", attached: true))
            }
            priority += AskRetrieval.liveMoments(question: question, meeting: live, limit: 3)
            priority += await sceneMoments(question, meeting: live, scenes: model.screenMoments, limit: 2)
        }
        var owners: [AttachmentOwner] = [.conversation(conversation.id)]
        if let scope { owners.append(.meeting(scope)) }
        let keywordsOnly = recording
        if let index {
            let refs = await index.attachmentRefs(owners)
            if !refs.isEmpty {
                priority += await index.moments(SearchRequest(question, limit: 6, perSource: 3, sourceRefs: refs),
                                                attached: true, keywordsOnly: keywordsOnly)
            }
            if let scope, scope != live?.id {
                priority += await index.moments(SearchRequest(question, limit: 4, perSource: 4, sourceRef: model.meetingSnapshot(scope)?.retention == "purged" ? model.meetingSnapshot(scope)?.vaultPath ?? scope : scope),
                                                attached: true, keywordsOnly: keywordsOnly)
            }
        }
        var general: [AskMoment] = []
        if let index {
            general = await index.moments(SearchRequest(question, limit: 12, perSource: 2), attached: false, keywordsOnly: keywordsOnly)
        }
        let context = AskContext(conversationID: conversation.id, scopeMeetingID: scope, recording: recording)
        for provider in providers {
            let extra = await provider.moments(for: question, context: context)
            priority += extra.filter(\.attached); general += extra.filter { !$0.attached }
        }
        let usable: (AskMoment) -> Bool = { moment in
            guard moment.isMeeting, let state = self.model.meetingSnapshot(moment.ref)?.retention else { return true }
            return state != "purged" && state != "purging"
        }
        var merged = AskRetrieval.merge(priority: priority.filter(usable), general: general.filter(usable), limit: 8, priorityShare: 5)
        for i in merged.indices where merged[i].kind == "screen" {
            let hit = merged[i]
            if let meeting = model.meetingSnapshot(hit.ref),
               let scene = model.store.loadScreenMoments(hit.ref).first(where: { $0.start == hit.start }) {
                let read = await model.readScene(scene, meetingID: hit.ref)
                merged[i] = Self.sceneMoment(read, meeting: meeting, folder: try? model.store.directory(hit.ref))
            }
        }
        var seen = Set<String>()
        return merged.filter { usable($0) && seen.insert($0.id).inserted }
    }

    /// Keyword-matching screen moments of the live meeting (they're indexed once the meeting is saved).
    static func screenMoments(_ question: String, meeting: Meeting, moments: [ScreenMoment], limit: Int) -> [AskMoment] {
        guard !moments.isEmpty else { return [] }
        let scores = (try? LexicalMatcher().similarities(notes: [question], chunks: moments.map(\.searchText)).first) ?? []
        return moments.indices.filter { $0 < scores.count && scores[$0] > 0.1 }.sorted { scores[$0] > scores[$1] }.prefix(limit).map { index in
            let moment = moments[index]
            var out = AskMoment(id: "screen:\(moment.id)", sourceKind: SourceKind.meeting.rawValue, ref: meeting.id, title: meeting.title,
                                kind: "screen", start: moment.start, end: moment.end, text: moment.searchText,
                                snippet: String(moment.text.prefix(200)), attached: true)
            out.window = moment.context
            return out
        }
    }

    // MARK: Attachments

    func attachments(_ owner: AttachmentOwner) -> [Attachment] {
        switch owner {
        case .conversation(let id): return conversation(id)?.attachments ?? []
        case .meeting(let id):
            if let cached = meetingAttachments[id] { return cached }
            return meetingFiles.load(id)
        }
    }

    func loadMeetingAttachments(_ id: String) {
        if meetingAttachments[id] == nil { meetingAttachments[id] = meetingFiles.load(id) }
    }

    func files(_ owner: AttachmentOwner) -> Attachments? {
        switch owner {
        case .conversation(let id): return try? store.attachments(id)
        case .meeting(let id):
            let retention = model.meetingSnapshot(id)?.retention
            guard retention != "purged", retention != "purging" else { return nil }
            return try? meetingFiles.files(id)
        }
    }

    func attach(files urls: [URL], to owner: AttachmentOwner) {
        guard let files = files(owner) else { return }
        for url in urls {
            do { add(try files.addFile(url), to: owner) }
            catch { model.message = "Couldn’t attach \(url.lastPathComponent): \(error.localizedDescription)" }
        }
    }

    func attachNote(_ text: String, title: String? = nil, to owner: AttachmentOwner) {
        guard let files = files(owner) else { return }
        do { add(try files.addNote(text, title: title), to: owner) }
        catch { model.message = "Couldn’t save the note: \(error.localizedDescription)" }
    }

    func remove(_ attachment: Attachment, from owner: AttachmentOwner) {
        let url = files(owner)?.url(of: attachment)
        files(owner)?.remove(attachment)
        save(attachments(owner).filter { $0.id != attachment.id }, for: owner)
        if let url, let index { Task { await index.removeAttachment(url) } }
    }

    /// Attaches and waits until it's searchable (the API and quick ask attach right before asking).
    func attachNow(path: String?, text: String?, to owner: AttachmentOwner) async throws -> Attachment {
        guard let files = files(owner) else { throw CaptureError.message("Invalid attachment owner") }
        var attachment: Attachment
        if let path { attachment = try files.addFile(URL(fileURLWithPath: path)) }
        else if let text { attachment = try files.addNote(text) }
        else { throw CaptureError.message("Give a path or text") }
        save(attachments(owner) + [attachment], for: owner)
        if let url = files.url(of: attachment), let index {
            let wordsOnly = recording
            if wordsOnly { needsEmbedding.append((url, owner, attachment.id)) }
            attachment.indexState = await index.indexAttachment(url, owner: owner, wordsOnly: wordsOnly)
            setState(attachment.indexState ?? "indexed", attachment.id, owner)
        }
        return attachment
    }

    func noteText(_ attachment: Attachment, owner: AttachmentOwner) -> String? { files(owner)?.noteText(attachment) }
    func url(_ attachment: Attachment, owner: AttachmentOwner) -> URL? { files(owner)?.url(of: attachment) }

    private func add(_ attachment: Attachment, to owner: AttachmentOwner) {
        save(attachments(owner) + [attachment], for: owner)
        if let url = files(owner)?.url(of: attachment) { reindex(url, owner: owner, attachmentID: attachment.id) }
    }

    private func save(_ list: [Attachment], for owner: AttachmentOwner) {
        switch owner {
        case .conversation(let id): update(id) { $0.attachments = list }
        case .meeting(let id):
            meetingAttachments[id] = list
            try? meetingFiles.save(list, for: id)
        }
    }

    private func reindex(_ url: URL, owner: AttachmentOwner, attachmentID: String) {
        guard let index else { setState("not indexed: search unavailable", attachmentID, owner); return }
        let wordsOnly = recording
        if wordsOnly { needsEmbedding.append((url, owner, attachmentID)) }
        Task { [weak self] in
            let state = await index.indexAttachment(url, owner: owner, wordsOnly: wordsOnly)
            self?.setState(state, attachmentID, owner)
        }
    }

    private func setState(_ state: String, _ attachmentID: String, _ owner: AttachmentOwner) {
        var list = attachments(owner)
        guard let position = list.firstIndex(where: { $0.id == attachmentID }) else { return }
        list[position].indexState = state
        save(list, for: owner)
    }

    private func prune() { if let index { Task { _ = await index.pruneAttachments() } } }

    /// Counts for the composer footer.
    func sourceSummary() async -> String {
        let folders = (try? await index?.folders().count) ?? 0
        let meetings = model.library.count
        return "\(meetings) meeting\(meetings == 1 ? "" : "s") · \(folders) folder\(folders == 1 ? "" : "s")"
    }
}

extension IndexService {
    /// Index hits as Ask moments. While recording, words only: the embedding model stays unloaded.
    func moments(_ request: SearchRequest, attached: Bool, keywordsOnly: Bool) async -> [AskMoment] {
        let results: SearchResults?
        if keywordsOnly { results = try? index.search(request) } else { results = try? await search(request) }
        return (results?.hits ?? []).map { AskMoment(hit: $0, attached: attached) }
    }

    func attachmentRefs(_ owners: [AttachmentOwner]) -> Set<String> {
        owners.reduce(into: Set<String>()) { $0.formUnion(AttachmentIndexer.refs(in: index, owner: $1)) }
    }

    /// Reads and indexes one attachment now. `wordsOnly` (while recording) skips embedding; the caller re-indexes
    /// with meaning once the recording ends.
    func indexAttachment(_ url: URL, owner: AttachmentOwner, wordsOnly: Bool) async -> String {
        let folders = FolderIndexer(index: index, embedder: wordsOnly ? nil : embedder, extractor: FileExtractors())
        let state = await AttachmentIndexer(folders: folders).index(url, owner: owner)
        if !wordsOnly { await embedder?.release() }
        index.invalidate()
        return state
    }

    func removeAttachment(_ url: URL) { try? index.remove(ref: url.path) }
    func pruneAttachments() -> Int { AttachmentIndexer.prune(index) }
}
