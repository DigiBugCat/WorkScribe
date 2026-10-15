import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WorkScribeCore

/// Chips for what's attached, each with remove; notes show their text on hover.
struct AttachmentStrip: View {
    @ObservedObject var ask: AskService
    let owner: AttachmentOwner

    var body: some View {
        let list = ask.attachments(owner)
        if !list.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(list) { attachment in AttachmentChip(ask: ask, owner: owner, attachment: attachment) }
                }.padding(.vertical, 2)
            }
        }
    }
}

struct AttachmentChip: View {
    @ObservedObject var ask: AskService
    let owner: AttachmentOwner
    let attachment: Attachment
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Theme.indigo)
            Text(attachment.name).font(.system(size: 12, weight: .medium)).lineLimit(1).frame(maxWidth: 180)
            if attachment.indexState == "pending" {
                ProgressView().controlSize(.mini)
            } else if let state = attachment.indexState, state != "indexed" {
                Image(systemName: "exclamationmark.circle").font(.system(size: 10)).foregroundStyle(Theme.ochre)
                    .help("Attached, but its text couldn’t be read (\(state)). Its name is still searchable.")
            }
            Button { ask.remove(attachment, from: owner) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(Theme.inkMuted).accessibilityLabel("Remove \(attachment.name)")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(attachment.kind == .note ? Theme.blush.opacity(0.45) : Theme.chip, in: Capsule())
        .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
        .help(help)
        .onTapGesture(count: 2) { if let url = ask.url(attachment, owner: owner) { NSWorkspace.shared.open(url) } }
        .contextMenu {
            Button("Open") { if let url = ask.url(attachment, owner: owner) { NSWorkspace.shared.open(url) } }
            Button("Show in Finder") { if let url = ask.url(attachment, owner: owner) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            Divider()
            Button("Remove", role: .destructive) { ask.remove(attachment, from: owner) }
        }
    }

    private var icon: String {
        if attachment.kind == .note { return "note.text" }
        switch FolderRules.kind(of: URL(fileURLWithPath: attachment.name)) {
        case .image: return "photo"
        case .audio: return "waveform"
        case .video: return "film"
        case .document: return attachment.name.lowercased().hasSuffix(".pdf") ? "doc.richtext" : "doc.text"
        default: return "paperclip"
        }
    }
    private var help: String {
        if attachment.kind == .note { return String((ask.noteText(attachment, owner: owner) ?? attachment.name).prefix(400)) }
        return attachment.originalPath ?? attachment.name
    }
}

/// Paperclip: attach files, or paste text as a note.
struct AttachMenu: View {
    let attachFiles: ([URL]) -> Void
    let addNote: () -> Void
    var body: some View {
        Menu {
            Button("Attach files…") { if let urls = AttachmentPicker.chooseFiles() { attachFiles(urls) } }
            Button("Paste text as note…") { addNote() }
            if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
                Text("Clipboard: \(text.prefix(40))…")
            }
        } label: { Image(systemName: "paperclip") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Attach files or a note").accessibilityLabel("Attach")
    }
}

enum AttachmentPicker {
    @MainActor static func chooseFiles() -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.prompt = "Attach"; panel.message = "Attach files to search and cite. They’re copied next to the chat or meeting."
        return panel.runModal() == .OK ? panel.urls : nil
    }
}

/// "Paste text as note": a title and the text, saved as Markdown with the conversation or meeting.
struct NoteComposer: View {
    let save: (String, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = NSPasteboard.general.string(forType: .string) ?? ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Attach a note").font(Theme.serif(20))
            TextField("Title (optional)", text: $title).textFieldStyle(.roundedBorder)
            TextEditor(text: $text).font(.system(size: 13)).frame(minHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
            Text("Saved as Markdown with this chat or meeting, searched and cited like a file.")
                .font(Theme.caption).foregroundStyle(Theme.inkMuted)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Attach") { save(text, title.isEmpty ? nil : title); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 480)
    }
}

/// Accepts dropped files (any type) and dropped text (as a note).
struct AttachmentDrop: ViewModifier {
    let files: ([URL]) -> Void
    let note: (String) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 10).stroke(Theme.indigo, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .background(Theme.indigoWash.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(Label("Drop to attach", systemImage: "paperclip").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.indigo))
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL, .plainText, .utf8PlainText], isTargeted: $targeted) { providers in
                handle(providers); return true
            }
    }

    private func handle(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { files([url]) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text, !text.isEmpty else { return }
                    DispatchQueue.main.async { note(text) }
                }
            }
        }
    }
}

extension View {
    func acceptsAttachments(files: @escaping ([URL]) -> Void, note: @escaping (String) -> Void) -> some View {
        modifier(AttachmentDrop(files: files, note: note))
    }
}
