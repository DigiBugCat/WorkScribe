import AppKit
import SwiftUI
import WorkScribeCore

/// The popover changes shape for each job: idle (start + recent recordings),
/// live (proof of capture + transcript), and reviewing one recording.
struct RecorderView: View {
    @ObservedObject var model: AppModel
    var openPlaud: () -> Void = {}
    /// Opens the floating window; nil when this view already is that window.
    var openWindow: (() -> Void)?
    var inWindow = false
    /// Shows this meeting (live while it records, else its review) regardless of the shared selection; the main
    /// window's meeting page uses it. `embedded` drops the status header and the back button, which the page owns.
    var meetingID: String? = nil
    var embedded = false
    @State private var followLive = true
    @State private var showingVoices = false
    @State private var query = ""
    @State private var pendingDelete: Meeting?
    @State private var editingTitle = false
    @State private var titleDraft = ""

    private enum Mode { case idle, live(Meeting), review(Meeting) }
    private var mode: Mode {
        if let meetingID {
            if let current = model.meeting, current.id == meetingID, model.busy,
               current.status == "recording" || current.status == "finalizing" || model.phase == "preview" { return .live(current) }
            if let entry = model.meeting?.id == meetingID ? model.meeting : model.library.first(where: { $0.id == meetingID }) {
                return .review(entry)
            }
            return .idle
        }
        if let current = model.meeting, model.busy,
           current.status == "recording" || current.status == "finalizing" || model.phase == "preview" {
            return .live(current)
        }
        if let id = model.selectedID,
           let entry = model.meeting?.id == id ? model.meeting : model.library.first(where: { $0.id == id }) {
            return .review(entry)
        }
        return .idle
    }

    var body: some View {
        VStack(spacing: 0) {
            if !embedded {
                StatusHeader(model: model, showingVoices: $showingVoices, openPlaud: openPlaud, openWindow: openWindow)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                Divider()
            }
            Group {
                switch mode {
                case .idle: idle
                case .live(let meeting): live(meeting)
                case .review(let meeting): review(meeting)
                }
            }.frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: embedded ? 320 : inWindow ? 360 : 400, idealWidth: 400, maxWidth: inWindow || embedded ? .infinity : 400,
               minHeight: embedded ? 300 : inWindow ? 420 : 580, idealHeight: 580, maxHeight: inWindow || embedded ? .infinity : 580)
        .overlay(alignment: .bottom) { toast }
        .sheet(isPresented: $showingVoices) { RememberedVoicesView(model: model) }
        .onChange(of: model.selectedID) { _, _ in editingTitle = false }
        .confirmationDialog("Move “\(pendingDelete?.title ?? "")” to the Trash?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { if let entry = pendingDelete { model.deleteRecording(id: entry.id) }; pendingDelete = nil }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { Text("Its audio and transcript go to the Trash, where you can still restore them.") }
    }

    /// Undo for speaker-name changes, shown for a few seconds after each one.
    @ViewBuilder private var toast: some View {
        if let toast = model.speakerToast {
            HStack(spacing: 10) {
                Text(toast.text).font(.callout).lineLimit(1)
                Button("Undo") { model.undoSpeakerChange(id: toast.meetingID) }
                    .buttonStyle(.borderless).fontWeight(.semibold)
                    .disabled(model.speakerUndo[toast.meetingID] == nil)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule()).shadow(radius: 4, y: 2)
            .padding(.bottom, 70)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: toast.id) {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if model.speakerToast?.id == toast.id { withAnimation { model.speakerToast = nil } }
            }
        }
    }

    /// Shown before recording when system audio is on but macOS won't allow it.
    @ViewBuilder private var screenAccessBanner: some View {
        if model.includeSystemAudio && !model.screenAccess {
            VStack(alignment: .leading, spacing: 6) {
                Label("System audio needs permission", systemImage: "speaker.slash").font(.callout.weight(.semibold))
                Text("Allow Screen & System Audio Recording so WorkScribe can hear the other side of calls. Until then it records your microphone only.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Allow…") { model.requestScreenAccess() }.controlSize(.small)
                    Button("Use mic only") { model.includeSystemAudio = false }.controlSize(.small).buttonStyle(.borderless)
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var filteredLibrary: [Meeting] {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return model.library }
        return model.library.filter { entry in
            entry.title.localizedCaseInsensitiveContains(term) || entry.segments.contains { $0.text.localizedCaseInsensitiveContains(term) }
        }
    }

    // MARK: Idle

    private var idle: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Button { Task { await model.start() } } label: {
                    HStack(spacing: 8) {
                        if !model.speechReady && model.phase != "error" || model.phase == "starting" {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "record.circle")
                        }
                        Text(startLabel)
                    }.frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(.teal).controlSize(.large)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.phase == "starting" || (!model.speechReady && model.phase != "error"))
                if model.globalShortcut && model.speechReady {
                    Text("Or press ⌥⌘R from any app").font(.caption2).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
                if let note = transientNote {
                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                screenAccessBanner
            }.padding(.horizontal, 16).padding(.top, 14)

            if model.library.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No recordings yet").font(.headline)
                    Text("Start a recording, or join a call with Auto-record on. Transcripts are saved on this Mac.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.horizontal, 16)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("RECENT").font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                            TextField("Search transcripts", text: $query).textFieldStyle(.plain).font(.caption)
                                .accessibilityLabel("Search recordings and transcripts")
                            if !query.isEmpty {
                                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("Clear search")
                            }
                        }
                        .padding(.horizontal, 7).padding(.vertical, 4).frame(width: 190)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    }.padding(.horizontal, 16)
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            if let status = model.importStatus, model.importActive {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    Spacer(minLength: 0)
                                }.padding(.horizontal, 8).padding(.vertical, 7)
                            }
                            ForEach(filteredLibrary) { entry in
                                RecordingRow(entry: entry, naming: model.namingIDs.contains(entry.id), query: query) {
                                    model.selectedID = entry.id
                                }
                                .contextMenu {
                                    Button("Open") { model.selectedID = entry.id }
                                    Button("Move to Trash…", role: .destructive) { pendingDelete = entry }
                                }
                            }
                            if filteredLibrary.isEmpty {
                                Text("No recordings mention “\(query)”.").font(.callout).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            }
                        }.padding(.horizontal, 8).padding(.bottom, 8)
                    }
                }
            }
        }
    }

    private var startLabel: String {
        if model.phase == "starting" { return model.message }
        if !model.speechReady && model.phase != "error" { return "Getting speech ready…" }
        return "Start recording"
    }

    /// Short-lived confirmations from the model ("Recording saved", "MCP configuration copied").
    private var transientNote: String? {
        let quiet = ["Record locally. Ask questions as the conversation unfolds.", "Starting recording…", "Waiting for audio permissions…"]
        guard model.phase == "ready", !quiet.contains(model.message) else { return nil }
        return model.message
    }

    // MARK: Live

    private func live(_ meeting: Meeting) -> some View {
        VStack(spacing: 0) {
            if model.recordingPressure != .normal {
                Text(model.message).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .accessibilityIdentifier("recording-backlog-status")
            }
            HStack(spacing: 6) {
                if model.namingIDs.contains(meeting.id) && meeting.titleOrigin == "pending" {
                    Text("Naming this recording…").foregroundStyle(.secondary)
                } else {
                    Text(meeting.titleOrigin == "pending" ? "Title appears once there's enough speech" : meeting.title)
                        .foregroundStyle(meeting.titleOrigin == "pending" ? .secondary : .primary)
                }
                Spacer(minLength: 8)
                if #unavailable(macOS 15) {
                    Toggle(isOn: $followLive) { Image(systemName: "arrow.down.to.line") }
                        .toggleStyle(.button).buttonStyle(.borderless).controlSize(.small)
                        .help(followLive ? "Following live speech. Click to stop following." : "Follow live speech")
                        .accessibilityLabel("Follow live transcript")
                }
            }
            .font(.callout.weight(.medium)).lineLimit(1)
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)

            if model.phase == "recording" {
                LevelMeters(levels: model.levels, systemBlocked: model.systemAudioBlocked, systemOff: !model.includeSystemAudio)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }
            if model.systemAudioBlocked {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.slash").foregroundStyle(.orange)
                    Text("Recording your mic only. System audio needs Screen Recording permission.")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Allow…") { model.requestScreenAccess() }.controlSize(.small)
                }
                .padding(8).background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
            Divider()

            TranscriptView(meeting: meeting, live: true, followLive: $followLive, editor: editor(meeting), focus: model.focusRequest)

            Divider()
            HStack {
                if model.phase == "preview" {
                    Label("Synthetic preview · no audio device is recording", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(role: .destructive) { Task { await model.stop() } } label: {
                        HStack { Image(systemName: "stop.fill"); Text(model.phase == "finalizing" ? "Saving transcript…" : "Stop recording") }
                            .frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.phase != "recording")
                    if model.phase == "finalizing", model.finalizationProgress >= 0.35 {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            if meeting.canResume(at: context.date) {
                                Button { Task { await model.start(resuming: meeting.id) } } label: {
                                    Label("Resume", systemImage: "play.fill")
                                }.controlSize(.small)
                            }
                        }
                    }
                }
            }.padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    // MARK: Review

    private func review(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if !embedded {
                    Button { model.selectedID = nil } label: { Label("Recent", systemImage: "chevron.left") }
                        .buttonStyle(.borderless).accessibilityLabel("Back to recent recordings")
                }
                Spacer()
                Menu {
                    Button("Rename…") { beginRename(meeting) }
                    Button("Export transcript…") { model.export() }.disabled(meeting.segments.isEmpty)
                    Divider()
                    Button("Check voice matches") { model.analyzeVoices(id: meeting.id) }
                        .disabled(model.busy || model.voiceJobs.contains(meeting.id) || meeting.segments.isEmpty)
                    Button("Undo speaker change") { model.undoSpeakerChange(id: meeting.id) }
                        .disabled(model.speakerUndo[meeting.id] == nil)
                    Divider()
                    Button("Show recordings in Finder") { model.revealRecordings() }
                    Button("Move to Trash…", role: .destructive) { pendingDelete = meeting }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Recording actions")
            }.padding(.horizontal, 12).padding(.top, 10)

            VStack(alignment: .leading, spacing: 4) {
                if editingTitle {
                    TextField("Title", text: $titleDraft)
                        .textFieldStyle(.plain).font(.title3.weight(.semibold))
                        .onSubmit { model.rename(id: meeting.id, to: titleDraft); editingTitle = false }
                        .onExitCommand { editingTitle = false }
                    Text("Press Return to save. Your title won't be replaced automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(meeting.title).font(.title3.weight(.semibold)).lineLimit(2)
                            .onTapGesture(count: 2) { beginRename(meeting) }
                        Button { beginRename(meeting) } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                            .help("Rename").accessibilityLabel("Rename recording")
                    }
                    HStack(spacing: 6) {
                        Text(RecordingRow.metadata(meeting))
                        if model.namingIDs.contains(meeting.id) {
                            ProgressView().controlSize(.mini); Text("Naming…")
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                    if let error = model.titleError[meeting.id] {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 10)

            if let failure = meeting.failure, meeting.status == "failed" || meeting.status == "interrupted" {
                FailureCallout(failure: failure, captured: !meeting.segments.isEmpty)
                    .padding(.horizontal, 16).padding(.bottom, 10)
            } else if let note = transientNote {
                Text(note).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 8)
            }

            if let purgeAt = meeting.purgeAt, meeting.retention == "finalized" {
                HStack {
                    Text("Transcript and recording deleted in \(max(0, Int(ceil(purgeAt.timeIntervalSinceNow / 3600)))) h")
                    Button("Done now") { Task {
                        do { try await model.retentionService?.done(meeting.id) }
                        catch { model.message = "Couldn’t finish cleanup: \(error.localizedDescription)" }
                    } }
                }.font(.caption).padding(.horizontal, 16).padding(.bottom, 8)
            }
            SuggestionStrip(meeting: meeting, confirm: { segment, suggestion in
                model.nameSpeaker(meetingID: meeting.id, segmentID: segment.id, name: suggestion.name,
                                  profileID: suggestion.profileID, wholeSpeaker: true, remember: true)
            }, reject: { segment in
                model.clearSpeaker(meetingID: meeting.id, segmentID: segment.id, wholeSpeaker: true)
            })

            Divider()
            if meeting.retention == "purged" || meeting.retention == "purging" {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Only your notes remain.")
                    if let path = meeting.vaultPath {
                        Button("Open note") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                        ScrollView {
                            Text((try? String(contentsOfFile: path, encoding: .utf8)) ?? "Open the vault note to read it.")
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.padding(16)
                Spacer()
            } else if meeting.segments.isEmpty && meeting.status == "failed" {
                Spacer()
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                if meeting.canResume(at: context.date) && !model.busy {
                    Button { Task { await model.start(resuming: meeting.id) } } label: {
                        Label("Resume recording", systemImage: "play.fill")
                    }.controlSize(.small).padding(.horizontal, 16).padding(.vertical, 8)
                }
            }
            TranscriptView(meeting: meeting, live: false, followLive: .constant(false), editor: editor(meeting), focus: model.focusRequest)
            }
        }
    }

    /// The naming popover shown on a speaker's label.
    private func editor(_ meeting: Meeting) -> (Segment, @escaping () -> Void) -> AnyView {
        { segment, done in
            AnyView(SpeakerNamingView(model: model, target: SpeakerEditTarget(meetingID: meeting.id, segment: segment), done: done))
        }
    }
    private func beginRename(_ meeting: Meeting) { titleDraft = meeting.title; editingTitle = true }
}

// MARK: - Status header

private struct StatusHeader: View {
    @ObservedObject var model: AppModel
    @Binding var showingVoices: Bool
    let openPlaud: () -> Void
    let openWindow: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            indicator.frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(headline).font(.headline)
                    if model.phase == "recording", let started = model.meeting?.startedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(AppModel.timestamp(context.date.timeIntervalSince(started)))
                                .font(.headline.monospacedDigit()).foregroundStyle(.red)
                        }
                    }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if let openWindow {
                Button(action: openWindow) { Image(systemName: "macwindow.on.rectangle") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Keep open in a floating window").accessibilityLabel("Open in a floating window")
            }
            settings
        }
    }

    @ViewBuilder private var indicator: some View {
        switch model.phase {
        case "recording":
            Image(systemName: "record.circle.fill").foregroundStyle(.red).symbolEffect(.bounce, value: model.meeting?.startedAt)
        case "finalizing":
            ProgressView(value: model.finalizationProgress).progressViewStyle(.circular).controlSize(.small)
        case "starting":
            ProgressView().controlSize(.small)
        case "error":
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case "preview":
            Image(systemName: "waveform").foregroundStyle(.teal)
        default:
            if model.speechReady { Circle().stroke(.tertiary, lineWidth: 1).frame(width: 8, height: 8) }
            else { ProgressView().controlSize(.small) }
        }
    }

    private var headline: String {
        switch model.phase {
        case "recording": return "Recording"
        case "starting": return "Starting"
        case "finalizing": return "Saving transcript"
        case "preview": return "Caption preview"
        case "error": return "Couldn’t record"
        default: return model.speechReady ? "Ready" : "Getting ready"
        }
    }

    private var detail: String {
        switch model.phase {
        case "recording":
            let trigger = model.meeting?.recordingTrigger ?? "manual"
            let source = model.systemAudioBlocked ? "Mic only, system audio blocked" : model.includeSystemAudio ? "Mic + system audio" : "Mic only"
            return trigger.hasPrefix("call:") ? "\(trigger.dropFirst(5)) call · started automatically · \(source)" : "\(source) · saved on this Mac"
        case "starting": return model.message
        case "finalizing": return model.message
        case "preview": return "No audio device is recording"
        case "error": return "See the recording below for what happened"
        default: return model.speechReady ? model.autoStatus : "Loading the speech model, about 15 seconds"
        }
    }

    private var settings: some View {
        Menu {
            Section("Recording") {
                Toggle("Auto-record calls", isOn: $model.autoRecordCalls).disabled(model.busy)
                Toggle("Include system audio", isOn: $model.includeSystemAudio).disabled(model.busy)
                Toggle("Capture the screen", isOn: $model.screenCaptureEnabled).disabled(model.busy)
                if model.screenState.isCapturing {
                    Toggle("Pause screen capture", isOn: $model.screenCapturePaused)
                }
                Toggle("Start and stop with ⌥⌘R", isOn: $model.globalShortcut)
            }
            Section("Speakers") {
                Button("Remembered voices…") { showingVoices = true }
            }
            if let vault = VaultHookup.shared { VaultSettingsSection(vault: vault) }
            Section("Ask") {
                Button("Quick ask   ⌥⌘K") { NotificationCenter.default.post(name: .workScribeShowQuickAsk, object: nil) }
                Button("Answers & cloud models…") { NotificationCenter.default.post(name: .workScribeShowCloudSettings, object: nil) }
            }
            #if WORKSCRIBE_PLAUD
            Section("Plaud Note Pro") {
                Button("Save & release Note Pro…") { openPlaud() }
            }
            #endif
            Section("Connect an LLM") {
                Button("Copy MCP config") { model.copyMCPConfig() }
            }
            Section {
                Button("Show recordings in Finder") { model.revealRecordings() }
                Button("Quit WorkScribe") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q").disabled(model.phase == "starting" || model.phase == "finalizing" || model.phase == "preview")
            }
            Section("Status") {
                Text(model.speechStatus)
                Text(model.voiceStatus)
                Text("NVIDIA speech + \(TitleModel.bundled.displayName) titles · entirely on this Mac")
            }
        } label: { Image(systemName: "gearshape") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Settings").accessibilityLabel("Settings")
    }
}

// MARK: - Recent list

private struct RecordingRow: View {
    let entry: Meeting
    let naming: Bool
    var query = ""
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.callout.weight(.medium)).lineLimit(1)
                        .foregroundStyle(failed ? .secondary : .primary)
                    Text(failed ? Self.failureSummary(entry) : Self.metadata(entry))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let snippet { Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2).italic() }
                }
                Spacer(minLength: 6)
                if naming { ProgressView().controlSize(.mini) }
                if failed {
                    Text(entry.status == "interrupted" ? "Interrupted" : "Failed")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                }
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(entry.title), \(failed ? Self.failureSummary(entry) : Self.metadata(entry))")
    }

    private var failed: Bool { entry.status == "failed" || entry.status == "interrupted" }
    /// When a search matches the transcript, show where.
    private var snippet: String? {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, !entry.title.localizedCaseInsensitiveContains(term),
              let text = entry.orderedSegments.first(where: { $0.text.localizedCaseInsensitiveContains(term) })?.text,
              let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + text[start..<end] + (end < text.endIndex ? "…" : "")
    }

    static func metadata(_ entry: Meeting) -> String {
        var parts = [when(entry.startedAt)]
        if entry.recordingTrigger?.hasPrefix("plaud:") == true { parts.insert("Note Pro", at: 0) }
        if let length = duration(entry) { parts.append(length) }
        let speakers = Set(entry.segments.map { $0.source + $0.speaker }).count
        if speakers > 0 { parts.append(speakers == 1 ? "1 speaker" : "\(speakers) speakers") }
        if entry.status == "recording" { parts.append("in progress") }
        return parts.joined(separator: " · ")
    }

    static func failureSummary(_ entry: Meeting) -> String {
        let reason = FailureCallout.explain(entry.failure ?? "").short
        return "\(when(entry.startedAt)) · \(entry.segments.isEmpty ? "Nothing captured" : "Partly saved") · \(reason)"
    }

    static func when(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "Today \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday \(time)" }
        return date.formatted(.dateTime.month(.abbreviated).day()) + " " + time
    }

    static func duration(_ entry: Meeting) -> String? {
        guard let end = entry.endedAt else { return nil }
        let seconds = Int(end.timeIntervalSince(entry.startedAt))
        guard seconds > 0 else { return nil }
        if seconds < 60 { return "\(seconds) sec" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) hr \(seconds % 3600 / 60) min"
    }
}

// MARK: - Failure explanation

struct FailureCallout: View {
    let failure: String
    let captured: Bool

    var body: some View {
        let info = Self.explain(failure)
        VStack(alignment: .leading, spacing: 6) {
            Label(info.title, systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold)).foregroundStyle(.orange)
            Text(captured ? "\(info.detail) What was captured before that is saved below." : info.detail)
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            if let url = info.settings {
                Button("Open Privacy & Security") { NSWorkspace.shared.open(url) }.controlSize(.small)
            }
            Text(failure).font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled).lineLimit(2)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    static func explain(_ raw: String) -> (title: String, detail: String, settings: URL?, short: String) {
        let text = raw.lowercased()
        if text.contains("tcc") || text.contains("display capture") || text.contains("screen") {
            return ("System audio was blocked",
                    "Screen Recording permission is off, so the recording couldn’t start. Allow WorkScribe under Screen & System Audio Recording, or turn off Include system audio in Settings.",
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"), "No screen permission")
        }
        if text.contains("microphone") {
            return ("Microphone access is off", "Allow WorkScribe under Microphone in Privacy & Security, then start again.",
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"), "No mic permission")
        }
        if text.contains("interrupted") {
            return ("Recording was interrupted", "WorkScribe quit before the recording finished.", nil, "Quit early")
        }
        if text.contains("keep up") {
            return ("Transcription fell behind", "The recording stopped because speech recognition couldn’t keep up.", nil, "Fell behind")
        }
        return ("Recording stopped early", "Something went wrong while recording.", nil, "Stopped early")
    }
}

// MARK: - Voice suggestions, once per speaker

private struct SuggestionStrip: View {
    let meeting: Meeting
    let confirm: (Segment, VoiceSuggestion) -> Void
    let reject: (Segment) -> Void

    var body: some View {
        let pending = (meeting.speakerSuggestions ?? [:]).compactMap { speaker, suggestion -> (Segment, VoiceSuggestion)? in
            guard let first = meeting.orderedSegments.first(where: {
                $0.speaker == speaker && meeting.assignment(for: $0) == nil && meeting.segmentAssignments?[$0.id] == nil
            }) else { return nil }
            return (first, suggestion)
        }.sorted { $0.0.start < $1.0.start }
        if !pending.isEmpty {
            VStack(spacing: 6) {
                ForEach(pending, id: \.0.id) { segment, suggestion in
                    HStack(spacing: 6) {
                        Image(systemName: "person.wave.2").foregroundStyle(.teal)
                        Text("\(Meeting.originalSpeakerName(segment.speaker)) sounds like **\(suggestion.name)**")
                        Spacer()
                        Button("Confirm") { confirm(segment, suggestion) }.controlSize(.small)
                        Button("Not them") { reject(segment) }.controlSize(.small).buttonStyle(.borderless)
                    }.font(.caption)
                }
            }
            .padding(8).background(.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16).padding(.bottom, 10)
        }
    }
}

// MARK: - Input levels

private struct LevelMeters: View {
    @ObservedObject var levels: LevelMonitor
    let systemBlocked: Bool
    let systemOff: Bool

    var body: some View {
        HStack(spacing: 14) {
            meter("Mic", systemImage: "mic.fill", value: levels.microphone)
            if systemBlocked || systemOff {
                Label(systemBlocked ? "System blocked" : "System off", systemImage: "speaker.slash")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                meter("System", systemImage: "speaker.wave.2.fill", value: levels.system ?? 0)
            }
        }
    }
    private func meter(_ title: String, systemImage: String, value: Float) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.caption2).foregroundStyle(.secondary).frame(width: 12)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule().fill(value > 0.9 ? Color.orange : Color.green)
                        .frame(width: max(3, proxy.size.width * CGFloat(value)))
                        .animation(.linear(duration: 0.1), value: value)
                }
            }.frame(height: 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) level \(Int(value * 100)) percent")
    }
}
