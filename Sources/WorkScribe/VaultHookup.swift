import AppKit
import Combine
import Foundation
import SwiftUI
import WorkScribeCore

extension Notification.Name {
    /// A page arrived from the browser extension. userInfo: "clip" (`SavedClip`), "kind" ("clip" or "ask"),
    /// and for asks "question" (String). The clip's text is untrusted page content.
    static let workScribeClipReceived = Notification.Name("WorkScribeClipReceived")
}

/// A page the user sent with "Ask WorkScribe about this page". `page` is untrusted data: quote it to the model as
/// source material inside a clearly delimited block, never as instructions.
struct ClipAsk: Identifiable, Equatable {
    let id: String
    let clip: SavedClip
    let page: PageCapture
    let question: String?
}

/// Connects the app to the notes vault and the browser extension:
/// - writes each finalized meeting to `Meetings/<date> <title>.md` (and `People/` pages), keeping it current as
///   titles, names and enhanced notes change, without overwriting the user's edits;
/// - watches the vault and indexes its Markdown (notes and web clips) for search;
/// - receives clips from the native host and attaches them to the live meeting or the Inbox.
///
/// UI hooks: `settings`/`choose()`/`useLocalFolder()` for Settings; `clips(for:)`, `recentClips` and the
/// `.workScribeClipReceived` notification for showing clips on a meeting; `pendingAsk` for quick ask;
/// `noteURL(for:)`/`obsidianURL(for:)` for "Open in Obsidian".
@MainActor
final class VaultHookup: ObservableObject {
    static private(set) var shared: VaultHookup?

    @Published private(set) var settings: VaultSettings
    @Published private(set) var status = ""
    /// Clips received since launch, newest first.
    @Published private(set) var recentClips: [SavedClip] = []
    /// The latest "Ask about this page" request, for the quick-ask UI to pick up (set to nil once handled).
    @Published var pendingAsk: ClipAsk?
    @Published private(set) var clipChannelError: String?

    private(set) var store: VaultStore
    private let model: AppModel
    private let index: IndexService?
    private var watcher: VaultWatcher?
    private var server: ClipSocketServer?
    private var libraryObservation: AnyCancellable?
    private var written: [String: String] = [:]
    private let launched = Date()
    static let stateDirectory = ProcessInfo.processInfo.environment["WORKSCRIBE_VAULT_STATE_DIR"]
        .map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/WorkScribe/Vault")

    init(model: AppModel, index: IndexService?) {
        self.model = model; self.index = index
        let saved = UserDefaults.standard.data(forKey: "vaultSettings").flatMap { try? JSONDecoder().decode(VaultSettings.self, from: $0) }
        let initial = saved ?? VaultSettings()
        settings = initial
        store = VaultStore(root: initial.root, stateDirectory: Self.stateDirectory)
        Self.shared = self
        libraryObservation = model.$library.receive(on: RunLoop.main).sink { [weak self] library in self?.syncMeetings(library) }
        applySettings()
        startClipChannel()
    }

    // MARK: Settings

    /// Lets the user pick an Obsidian vault or any folder.
    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Use as Vault"
        panel.message = "Choose your Obsidian vault, or any folder. WorkScribe writes Meetings/, People/ and Clippings/ there and never touches .obsidian."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        update { $0.path = FileIdentity.url(url).path }
    }

    /// Back to WorkScribe's own notes folder.
    func useLocalFolder() { update { $0.path = nil } }
    func setWriteMeetings(_ value: Bool) { update { $0.writeMeetings = value } }
    func setIndexVault(_ value: Bool) { update { $0.indexVault = value } }

    private func update(_ change: (inout VaultSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        if let data = try? JSONEncoder().encode(next) { UserDefaults.standard.set(data, forKey: "vaultSettings") }
        applySettings()
    }

    private func applySettings() {
        store = VaultStore(root: settings.root, stateDirectory: Self.stateDirectory)
        model.retentionService?.vault = store
        written = [:]
        watcher?.stop(); watcher = nil
        let root = store.root
        status = settings.path == nil ? "Notes are kept in WorkScribe’s folder"
            : store.isObsidianVault ? "Writing to the “\(store.name)” vault" : "Writing to \(root.lastPathComponent)"
        guard let index else { return }
        let indexVault = settings.indexVault
        Task {
            await index.setVault(indexVault ? root : nil)
            guard indexVault else { return }
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let checkpoint = await index.vaultCheckpoint(root)
            let watcher = VaultWatcher(root: root) { change in
                Task {
                    switch change {
                    case .paths(let paths, let checkpoint): await index.vaultChanged(root: root, paths: paths, checkpoint: checkpoint)
                    case .rescan(_, let checkpoint): await index.vaultChanged(root: root, paths: nil, checkpoint: checkpoint)
                    }
                }
            }
            await MainActor.run { self.watcher = watcher }
            watcher.start(since: checkpoint)
        }
        syncMeetings(model.library)
    }

    var displayName: String { settings.path == nil ? "WorkScribe notes" : store.name }

    // MARK: Meetings → vault

    /// The note's file, when WorkScribe wrote one.
    func noteURL(for meetingID: String) -> URL? { store.notePath(forMeeting: meetingID).map(store.url) }
    /// `obsidian://open?vault=…&file=…` for the meeting's note.
    func obsidianURL(for meetingID: String) -> URL? { store.notePath(forMeeting: meetingID).flatMap(store.obsidianURL) }

    /// Writes (or refreshes) one meeting now, e.g. from an "Add to vault" button for an older recording.
    @discardableResult
    func write(meetingID: String) -> VaultStore.Outcome? {
        guard let meeting = model.library.first(where: { $0.id == meetingID }) else { return nil }
        return write(meeting)
    }

    private func syncMeetings(_ library: [Meeting]) {
        guard settings.writeMeetings else { return }
        for meeting in library where meeting.status == "complete" && meeting.retention == "finalized" {
            // New recordings, and ones already in the vault; never a silent backfill of the whole library.
            let recent = (meeting.endedAt ?? .distantPast) > launched
            guard recent || store.hasNote(forMeeting: meeting.id) else { continue }
            // Wait for the generated title unless it failed or is taking long.
            let ended = meeting.endedAt ?? meeting.startedAt
            if meeting.titleOrigin == "pending", model.titleError[meeting.id] == nil, Date().timeIntervalSince(ended) < 180 { continue }
            write(meeting)
        }
    }

    @discardableResult
    private func write(_ meeting: Meeting) -> VaultStore.Outcome? {
        let fingerprint = Self.fingerprint(meeting, clips: store.clips(forMeeting: meeting.id).count)
        guard written[meeting.id] != fingerprint else { return nil }
        do {
            let outcome = try store.writeMeeting(meeting)
            written[meeting.id] = fingerprint
            if case .conflicted(_, let conflict, _) = outcome { status = "You edited a meeting note; WorkScribe’s update is in \(conflict)" }
            return outcome
        } catch {
            status = "Couldn’t write the meeting note: \(error.localizedDescription)"
            return nil
        }
    }

    static func fingerprint(_ meeting: Meeting, clips: Int) -> String {
        let notes = (meeting.notes ?? []).map { "\($0.id)=\($0.line.text ?? $0.text)|\(($0.line.evidence ?? []).joined(separator: ","))" }
        let missed = (meeting.missedTopics ?? []).map { "\($0.topic):\($0.text)" }
        let parts = [meeting.retention ?? "", meeting.title, meeting.endedAt?.description ?? "", MeetingWriteUp.namedVoices(meeting).joined(separator: ","),
                     notes.joined(separator: "\n"), missed.joined(separator: "\n"), String(clips)]
        return VaultWriter.hash(parts.joined(separator: "\u{1E}"))
    }

    // MARK: Clips from the browser

    func clips(for meetingID: String) -> [SavedClip] { store.clips(forMeeting: meetingID) }

    private func startClipChannel() {
        let server = ClipSocketServer { request in await VaultHookup.handle(request) }
        do { try server.start(); self.server = server }
        catch { clipChannelError = "Browser clipping is off: \(error)" }
    }

    func stop() { server?.stop(); server = nil; watcher?.stop() }

    nonisolated static func handle(_ request: ClipRequest) async -> ClipResponse {
        await MainActor.run {
            guard let hookup = shared else { return .failure(request.id, "not_running", "WorkScribe is starting") }
            return hookup.receive(request)
        }
    }

    /// The live meeting a clip would join right now.
    private var liveMeeting: Meeting? { model.phase == "recording" ? model.meeting : nil }

    func receive(_ request: ClipRequest) -> ClipResponse {
        var target: Meeting?
        if let wanted = request.meetingId {
            // The popup showed this meeting; honour it even if it just ended.
            target = liveMeeting?.id == wanted ? liveMeeting : model.library.first { $0.id == wanted }
        } else { target = liveMeeting }
        let offset = target.flatMap { meeting -> Double? in
            let seconds = Date().timeIntervalSince(meeting.startedAt)
            if let ended = meeting.endedAt, Date() > ended { return nil }
            return seconds
        }
        let destination = target.map { ClipResponse.Destination(kind: "meeting", title: $0.title, meetingId: $0.id, offset: offset) }
            ?? ClipResponse.Destination(kind: "inbox", title: "Inbox")

        guard request.type != .status, let page = request.page else {
            return ClipResponse(id: request.id, ok: true, destination: destination, vault: displayName)
        }
        do {
            let clip = try store.saveClip(page, meeting: target.map { ($0.id, $0.title) }, offset: offset)
            recentClips.insert(clip, at: 0)
            if recentClips.count > 50 { recentClips.removeLast() }
            if let target, target.status == "complete", store.hasNote(forMeeting: target.id) { write(target) }
            if settings.indexVault, let index {
                let root = store.root, path = store.url(clip.path).path
                Task { await index.vaultChanged(root: root, paths: [path], checkpoint: nil) }
            }
            var info: [String: Any] = ["clip": clip, "kind": request.type.rawValue]
            if request.type == .ask {
                pendingAsk = ClipAsk(id: request.id, clip: clip, page: page, question: request.question)
                if let question = request.question { info["question"] = question }
            }
            NotificationCenter.default.post(name: .workScribeClipReceived, object: self, userInfo: info)
            var done = destination
            done.path = clip.path
            return ClipResponse(id: request.id, ok: true, destination: done, vault: displayName)
        } catch {
            return .failure(request.id, "failed", "Couldn’t save the clip: \(error.localizedDescription)")
        }
    }
}

/// Settings → Notes vault (a section inside the settings menu).
struct VaultSettingsSection: View {
    @ObservedObject var vault: VaultHookup
    var body: some View {
        Section("Notes vault") {
            Text(vault.settings.path.map { "Vault: \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "Vault: WorkScribe’s folder")
            Button("Choose Obsidian vault or folder…") { vault.choose() }
            if vault.settings.path != nil { Button("Use WorkScribe’s folder instead") { vault.useLocalFolder() } }
            Toggle("Write meeting notes to the vault", isOn: Binding(get: { vault.settings.writeMeetings }, set: { vault.setWriteMeetings($0) }))
            Toggle("Search the vault", isOn: Binding(get: { vault.settings.indexVault }, set: { vault.setIndexVault($0) }))
            if let error = vault.clipChannelError { Text(error) }
        }
    }
}
