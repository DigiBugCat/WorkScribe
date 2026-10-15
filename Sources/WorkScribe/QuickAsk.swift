import AppKit
import SwiftUI
import WorkScribeCore

extension Notification.Name {
    /// ⌘↩ in quick ask: the conversation should continue in the workspace (the Obsidian plugin opens it from the
    /// `continue` event on /v1/events). userInfo: "conversation_id".
    static let workScribeContinueConversation = Notification.Name("WorkScribeContinueConversation")
    static let workScribeShowQuickAsk = Notification.Name("WorkScribeShowQuickAsk")
    static let workScribeShowCloudSettings = Notification.Name("WorkScribeShowCloudSettings")
}

/// A borderless panel that takes keyboard focus above any app without activating WorkScribe (Spotlight-like).
final class QuickAskPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

@MainActor
final class QuickAskController {
    private var panel: QuickAskPanel?
    private let ask: AskService
    private let model: AppModel
    private let state = QuickAskState()
    var openLink: (WorkScribeLink) -> Void = { _ in }

    init(ask: AskService, model: AppModel) { self.ask = ask; self.model = model }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() { isVisible ? close() : show() }

    func show() {
        if panel == nil {
            let view = QuickAskView(ask: ask, model: model, state: state, close: { [weak self] in self?.close() },
                                    openLink: { [weak self] link in self?.openLink(link) })
            let hosting = NSHostingController(rootView: view)
            hosting.sizingOptions = [.preferredContentSize]
            let panel = QuickAskPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 120),
                                      styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
            panel.contentViewController = hosting
            panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.isMovableByWindowBackground = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.backgroundColor = Theme.dynamicNS(light: 0xf9f5ec, dark: 0x2b3b35)
            self.panel = panel
        }
        // A fresh question each time, unless an answer is still being written.
        if let id = state.conversationID, !ask.working.contains(id),
           let updated = ask.conversation(id)?.updatedAt, Date().timeIntervalSince(updated) > 120 {
            state.conversationID = nil
        }
        state.focusToken += 1
        position()
        panel?.makeKeyAndOrderFront(nil)
    }

    func close() { panel?.orderOut(nil) }

    /// Top third of the screen with the mouse, like Spotlight.
    private func position() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { panel.center(); return }
        let size = panel.frame.size
        panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - frame.height * 0.22))
    }
}

@MainActor
final class QuickAskState: ObservableObject {
    @Published var conversationID: String?
    @Published var focusToken = 0
}

struct QuickAskView: View {
    @ObservedObject var ask: AskService
    @ObservedObject var model: AppModel
    @ObservedObject var state: QuickAskState
    let close: () -> Void
    let openLink: (WorkScribeLink) -> Void
    @State private var draft = ""
    @State private var addingNote = false
    @State private var copied = false
    @FocusState private var focused: Bool

    private var conversation: Conversation? { ask.conversation(state.conversationID) }
    private var lastTurn: [AskMessage] { Array(conversation?.messages.suffix(2) ?? []) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass").font(.system(size: 20)).foregroundStyle(Theme.indigo)
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.plain).font(.system(size: 20))
                    .focused($focused)
                    .onSubmit(send)
                if let id = state.conversationID, ask.working.contains(id) {
                    ProgressView().controlSize(.small)
                }
                AttachMenu(attachFiles: { attach($0) }, addNote: { addingNote = true })
            }
            if let id = state.conversationID, !(conversation?.attachments.isEmpty ?? true) {
                AttachmentStrip(ask: ask, owner: .conversation(id))
            }
            if let live = ask.liveMeeting {
                Label("Recording “\(live.title)”: this call and its screen are searched first", systemImage: "record.circle")
                    .font(Theme.caption).foregroundStyle(Theme.inkMuted)
            }
            if !lastTurn.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(lastTurn) { message in MessageView(message: message, open: openLink, compact: true) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 380)
            }
            HStack(spacing: 14) {
                hint("↩", "Ask"); hint("⌘↩", copied ? "Copied · continue in Obsidian" : "Continue in Obsidian"); hint("esc", "Close")
                Spacer()
                Text(ask.generatorName ?? "Moments only").font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
            }
        }
        .padding(16)
        .frame(width: 640)
        .background(Theme.surfaceRaised)
        .acceptsAttachments(files: { attach($0) }, note: { text in ask.attachNote(text, to: owner()) })
        .sheet(isPresented: $addingNote) { NoteComposer { text, title in ask.attachNote(text, title: title, to: owner()) } }
        .onAppear { focused = true }
        .onChange(of: state.focusToken) { _, _ in focused = true; copied = false }
        .onExitCommand(perform: close)
        .background {
            Button("", action: continueInWorkspace).keyboardShortcut(.return, modifiers: .command).opacity(0)
        }
    }

    private var placeholder: String { ask.liveMeeting != nil ? "Ask about this call…" : "Ask WorkScribe…" }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 4).padding(.vertical, 1)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 3))
            Text(label).font(.system(size: 11))
        }.foregroundStyle(Theme.inkMuted)
    }

    private func owner() -> AttachmentOwner {
        let id = ask.ensureConversation(state.conversationID, origin: "quick")
        state.conversationID = id
        return .conversation(id)
    }

    private func attach(_ urls: [URL]) { ask.attach(files: urls, to: owner()) }

    private func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        draft = ""
        state.conversationID = ask.ask(question, in: state.conversationID, origin: "quick").conversation
    }

    /// Copies the answer with its sources and tells the workspace (Obsidian plugin) to open the conversation.
    private func continueInWorkspace() {
        if !draft.trimmingCharacters(in: .whitespaces).isEmpty { send() }
        guard let id = state.conversationID, let conversation = ask.conversation(id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.markdown(conversation), forType: .string)
        NotificationCenter.default.post(name: .workScribeContinueConversation, object: nil, userInfo: ["conversation_id": id])
        copied = true
    }

    static func markdown(_ conversation: Conversation) -> String {
        conversation.messages.map { message in
            if message.role == .user { return "**Q:** \(message.text)" }
            let sources = message.citations.map { "[\($0.number)] [\($0.moment.sourceName) · \($0.moment.locator)](\($0.moment.link.url.absoluteString))" }
            return ([message.text] + sources).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
