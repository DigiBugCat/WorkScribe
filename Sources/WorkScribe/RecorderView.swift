import AppKit
import SwiftUI
import WorkScribeCore

/// The popover changes shape for each job: idle (start + recent recordings),
/// live (proof of capture + transcript), and reviewing one recording.
struct RecorderView: View {
    @ObservedObject var model: AppModel
    var openPlaud: () -> Void = {}
    @State private var followLive = true
    @State private var speakerEdit: SpeakerEditTarget?
    @State private var showingVoices = false
    @State private var editingTitle = false
    @State private var titleDraft = ""

    private enum Mode { case idle, live(Meeting), review(Meeting) }
    private var mode: Mode {
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
            StatusHeader(model: model, showingVoices: $showingVoices, openPlaud: openPlaud)
                .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            Group {
                switch mode {
                case .idle: idle
                case .live(let meeting): live(meeting)
                case .review(let meeting): review(meeting)
                }
            }.frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 400, height: 580)
        .sheet(item: $speakerEdit) { target in SpeakerNamingView(model: model, target: target) }
        .sheet(isPresented: $showingVoices) { RememberedVoicesView(model: model) }
        .onChange(of: model.selectedID) { _, _ in editingTitle = false }
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
                if let note = transientNote {
                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.horizontal, 16).padding(.top, 14)

            if model.library.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No recordings yet").font(.headline)
                    Text("Start a recording, or join a call with Auto-record on. Transcripts are saved on this Mac.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.horizontal, 16)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("RECENT").font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            if let status = model.importStatus, model.importActive {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    Spacer(minLength: 0)
                                }.padding(.horizontal, 8).padding(.vertical, 7)
                            }
                            ForEach(model.library) { entry in
                                RecordingRow(entry: entry, naming: model.namingIDs.contains(entry.id)) {
                                    model.selectedID = entry.id
                                }
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
            HStack(spacing: 6) {
                if model.namingIDs.contains(meeting.id) && meeting.titleOrigin == "pending" {
                    Text("Naming this recording…").foregroundStyle(.secondary)
                } else {
                    Text(meeting.titleOrigin == "pending" ? "Title appears once there's enough speech" : meeting.title)
                        .foregroundStyle(meeting.titleOrigin == "pending" ? .secondary : .primary)
                }
                Spacer(minLength: 8)
                Toggle(isOn: $followLive) { Image(systemName: "arrow.down.to.line") }
                    .toggleStyle(.button).buttonStyle(.borderless).controlSize(.small)
                    .help(followLive ? "Following live speech. Click to stop following." : "Follow live speech")
                    .accessibilityLabel("Follow live transcript")
            }
            .font(.callout.weight(.medium)).lineLimit(1)
            .padding(.horizontal, 16).padding(.vertical, 10)

            TranscriptView(meeting: meeting, live: true, followLive: $followLive, nameSpeaker: edit(meeting))

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
                }
            }.padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    // MARK: Review

    private func review(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { model.selectedID = nil } label: { Label("Recent", systemImage: "chevron.left") }
                    .buttonStyle(.borderless).accessibilityLabel("Back to recent recordings")
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

            SuggestionStrip(meeting: meeting, voices: model.voices) { segment in
                speakerEdit = SpeakerEditTarget(meetingID: meeting.id, segment: segment)
            }

            Divider()
            if meeting.segments.isEmpty && meeting.status == "failed" {
                Spacer()
            } else {
                TranscriptView(meeting: meeting, live: false, followLive: .constant(false), nameSpeaker: edit(meeting))
            }
        }
    }

    private func edit(_ meeting: Meeting) -> (Segment) -> Void {
        { segment in speakerEdit = SpeakerEditTarget(meetingID: meeting.id, segment: segment) }
    }
    private func beginRename(_ meeting: Meeting) { titleDraft = meeting.title; editingTitle = true }
}

// MARK: - Status header

private struct StatusHeader: View {
    @ObservedObject var model: AppModel
    @Binding var showingVoices: Bool
    let openPlaud: () -> Void

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
            settings
        }
    }

    @ViewBuilder private var indicator: some View {
        switch model.phase {
        case "recording":
            Image(systemName: "record.circle.fill").foregroundStyle(.red).symbolEffect(.pulse)
        case "starting", "finalizing":
            ProgressView().controlSize(.small)
        case "error":
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case "preview":
            Image(systemName: "waveform").foregroundStyle(.teal)
        default:
            if model.speechReady { Circle().fill(.green).frame(width: 8, height: 8) }
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
            let source = model.includeSystemAudio ? "Mic + system audio" : "Mic only"
            return trigger.hasPrefix("call:") ? "\(trigger.dropFirst(5)) call · started automatically · \(source)" : "\(source) · saved on this Mac"
        case "starting": return model.message
        case "finalizing": return "Finishing the last words…"
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
            }
            Section("Speakers") {
                Button("Remembered voices…") { showingVoices = true }
            }
            Section("Plaud Note Pro") {
                Button("Save & release Note Pro…") { openPlaud() }
            }
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

private struct FailureCallout: View {
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
    let voices: [VoiceProfile]
    let review: (Segment) -> Void

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
                        Button("Review") { review(segment) }.controlSize(.small)
                    }.font(.caption)
                }
            }
            .padding(8).background(.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16).padding(.bottom, 10)
        }
    }
}
