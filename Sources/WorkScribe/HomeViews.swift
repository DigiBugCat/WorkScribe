import AppKit
import SwiftUI
import WorkScribeCore

// The popover around everything WorkScribe does. Two things are always on, the screen and calls: each
// has a row that says what it is doing and holds its one control. Below them is one box to ask of all
// of it, and the day the two produce. The footer says what stays on this Mac and who writes the notes.

// MARK: - The two sensors

struct SensorHeader: View {
    @ObservedObject var model: AppModel
    @State private var allowing: ScreenAppRef?
    @State private var forgetting: ScreenAppRef?

    var body: some View {
        VStack(spacing: 6) {
            // Whichever is doing the most comes first.
            if model.busy { calls; screen } else { screen; calls }
        }
        .confirmationDialog("Read \(allowing?.name ?? "this app")’s windows?", isPresented: Binding(
            get: { allowing != nil }, set: { if !$0 { allowing = nil } }), titleVisibility: .visible) {
            Button("Read \(allowing?.name ?? "it")") { if let id = allowing?.bundleID { model.setScreenReading(true, for: id) }; allowing = nil }
            Button("Cancel", role: .cancel) { allowing = nil }
        } message: { Text("It is on the list of apps that are never read. Its text will be kept like any other app’s.") }
        .confirmationDialog("Forget what was read from \(forgetting?.name ?? "this app") today?", isPresented: Binding(
            get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }), titleVisibility: .visible) {
            Button("Forget", role: .destructive) {
                if let id = forgetting?.bundleID { Task { await model.forgetScreenApp(id, day: ScreenDayStore.day(Date()).id) } }
                forgetting = nil
            }
            Button("Cancel", role: .cancel) { forgetting = nil }
        } message: { Text("Its text, and that it was in front, are deleted from today’s history. This can’t be undone.") }
    }

    // MARK: Screen

    private var screen: some View {
        SensorRow(name: "Screen", help: model.screenMode == .off ? "" : model.screenState.label) {
            SensorDot(kind: screenDot)
        } state: { screenState } control: { screenControl }
    }

    private var screenDot: SensorDot.Kind {
        guard model.screenMode != .off else { return .idle }
        switch model.screenState {
        case .recording: return .on
        case .starting: return .working
        case .unavailable, .failed: return .attention
        default: return .idle
        }
    }

    @ViewBuilder private var screenState: some View {
        if model.screenMode == .off {
            Text("Off")
        } else {
            switch model.screenState {
            case .recording:
                let tail = model.phase == "recording" ? " for this meeting" : ""
                if let app = model.screenApp?.name { Text("Reading \(Text(app).foregroundStyle(.primary))\(tail)") }
                else { Text("Reading the window in front" + tail) }
            case .paused: Text("Paused")
            case .privateApp(let name): Text("Not reading \(Text(name).foregroundStyle(.primary))")
            case .starting: Text("Starting…")
            case .unavailable: Text("Needs permission to read windows")
            case .failed(let why): Text("Stopped: \(why)")
            case .off: Text(model.screenMode == .meetings ? "Reads during meetings" : "Starting…")
            }
        }
    }

    @ViewBuilder private var screenControl: some View {
        if model.screenMode == .off {
            Button("Turn on") {
                model.screenMode = .allDay
                if !ScreenReader.accessibilityAllowed { ScreenReader.askForAccessibility() }
            }.controlSize(.small).disabled(model.busy)
        } else if case .unavailable = model.screenState {
            Button("Allow…") {
                if !ScreenReader.accessibilityAllowed { ScreenReader.askForAccessibility() }
                if !ScreenReader.picturesAllowed { model.requestScreenAccess() }
            }.controlSize(.small)
        } else if model.screenCapturePaused {
            Button("Resume") { model.resumeScreen() }.controlSize(.small)
        } else if case .privateApp(let name) = model.screenState, let id = model.screenHiddenBundleID {
            Button("Allow…") { allowing = ScreenAppRef(name: name, bundleID: id) }.controlSize(.small)
        } else {
            Menu {
                Button("Pause for 15 minutes") { model.pauseScreen(minutes: 15) }
                Button("Pause for an hour") { model.pauseScreen(minutes: 60) }
                Button("Pause until I resume") { model.pauseScreen() }
                if let app = model.screenApp, let id = app.bundleID {
                    Divider()
                    Button("Never read \(app.name)") { model.setScreenReading(false, for: id) }
                    if model.screenMode == .allDay { Button("Forget what was read from \(app.name) today…") { forgetting = app } }
                }
                Divider()
                Picker("Read the screen", selection: Binding(get: { model.screenMode }, set: { model.screenMode = $0 })) {
                    ForEach(ScreenReadingMode.allCases) { Text($0.label).tag($0) }
                }.disabled(model.busy)
                if model.screenMode == .allDay { Button("Screen history…") { ScreenHistoryWindow.open(model: model) } }
            } label: { Text("Pause") }
                .menuStyle(.button).controlSize(.small).fixedSize()
                .disabled(!model.screenState.isCapturing && model.screenState != .off)
                .accessibilityLabel("Pause screen reading, and more")
        }
    }

    // MARK: Calls

    private var calls: some View {
        SensorRow(name: "Calls", help: model.phase == "error" ? model.message : "") {
            SensorDot(kind: callsDot)
        } state: { callsState } control: { callsControl }
    }

    private var callsDot: SensorDot.Kind {
        switch model.phase {
        case "recording": return .recording
        case "starting", "finalizing": return .working
        case "error": return .attention
        case "preview": return .on
        default: return model.speechReady ? .idle : .working
        }
    }

    @ViewBuilder private var callsState: some View {
        switch model.phase {
        case "recording":
            HStack(spacing: 5) {
                if let started = model.meeting?.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(AppModel.timestamp(context.date.timeIntervalSince(started)))
                            .monospacedDigit().fontWeight(.semibold).foregroundStyle(.red)
                    }
                }
                Text("· " + recordingDetail)
            }
        case "starting", "finalizing": Text(model.message)
        case "preview": Text("Caption preview · no audio device is recording")
        // Why, in the app's own words ("Zoom isn’t in a meeting."): a tooltip alone left the person guessing.
        case "error": Text(model.message.isEmpty ? "Couldn’t record" : model.message).foregroundStyle(.primary)
        default: Text(model.speechReady ? model.autoStatus : "Getting speech ready, about 15 seconds")
        }
    }

    private var recordingDetail: String {
        let trigger = model.meeting?.recordingTrigger ?? "manual"
        let source = model.systemAudioBlocked ? "mic only, system audio blocked"
            : model.microphoneIssue != nil ? "call audio only, mic unavailable"
            : model.includeSystemAudio ? "mic + system audio" : "mic only"
        return trigger.hasPrefix("call:") ? "\(trigger.dropFirst(5)) call · \(source)" : source
    }

    @ViewBuilder private var callsControl: some View {
        switch model.phase {
        case "recording":
            Button { Task { await model.stop() } } label: { Label("Stop", systemImage: "stop.fill").labelStyle(.titleAndIcon) }
                .buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
                .keyboardShortcut("r", modifiers: .command).help("Stop recording")
        case "finalizing":
            if let meeting = model.meeting, model.finalizationProgress >= 0.35 {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if meeting.canResume(at: context.date) {
                        Button("Resume") { Task { await model.start(resuming: meeting.id) } }.controlSize(.small)
                    }
                }
            }
        case "starting", "preview":
            EmptyView()
        default:
            Button { Task { await model.start() } } label: { Label("Record", systemImage: "record.circle").labelStyle(.titleAndIcon) }
                .buttonStyle(.borderedProminent).tint(.teal).controlSize(.small)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.speechReady && model.phase != "error")
                .help(model.globalShortcut ? "Start recording. Or press ⌥⌘R from any app." : "Start recording")
        }
    }
}

private struct SensorRow<Dot: View, StateView: View, Control: View>: View {
    let name: String
    var help = ""
    @ViewBuilder var dot: Dot
    @ViewBuilder var state: StateView
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 8) {
            dot.frame(width: 14, height: 14)
            Text(name).font(.callout.weight(.semibold)).frame(width: 48, alignment: .leading)
            state.font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading).help(help)
            control
        }
        .frame(minHeight: 24)
    }
}

struct SensorDot: View {
    enum Kind { case on, idle, recording, attention, working }
    let kind: Kind

    var body: some View {
        switch kind {
        case .on: lit(.teal)
        case .recording: lit(.red)
        case .idle: Circle().stroke(.tertiary, lineWidth: 1.2).frame(width: 8, height: 8)
        case .attention: Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        case .working: ProgressView().controlSize(.mini)
        }
    }
    private func lit(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .background(Circle().fill(color.opacity(0.22)).frame(width: 14, height: 14))
    }
}

// MARK: - The day

/// Today: a strip of the day, then meetings and stretches of one app, newest first.
struct DayView: View {
    @ObservedObject var model: AppModel
    private static let palette: [Color] = [.blue, .orange, .green, .purple]

    var body: some View {
        // The open stretch grows and "now" moves on without anything else changing.
        TimelineView(.periodic(from: .now, by: 30)) { context in content(now: context.date) }
    }

    private func build(now: Date) -> (timeline: DayTimeline, start: Date) {
        let start = Calendar.current.startOfDay(for: now)
        let spans = model.screenUsage.start == start ? model.screenUsage.spans : []
        var entries = model.library
        if let current = model.meeting, !entries.contains(where: { $0.id == current.id }) { entries.insert(current, at: 0) }
        let meetings = entries.filter { $0.startedAt >= start && $0.startedAt < start.addingTimeInterval(86_400) }.map { entry -> DayTimeline.MeetingRef in
            let began = entry.startedAt.timeIntervalSince(start)
            let live = model.busy && model.meeting?.id == entry.id
            return DayTimeline.MeetingRef(id: entry.id, title: entry.title, start: began,
                                          end: live ? nil : entry.endedAt?.timeIntervalSince(start) ?? began)
        }
        return (DayTimeline.build(spans: spans, meetings: meetings, now: now.timeIntervalSince(start)), start)
    }

    private func color(_ key: String, _ timeline: DayTimeline) -> Color {
        timeline.totals.prefix(Self.palette.count).firstIndex { $0.key == key }.map { Self.palette[$0] } ?? .gray
    }

    @ViewBuilder private func content(now: Date) -> some View {
        let day = build(now: now)
        VStack(alignment: .leading, spacing: 0) {
            if !day.timeline.segments.isEmpty {
                DayStrip(timeline: day.timeline, color: { color($0, day.timeline) })
                    .padding(.horizontal, 14)
                    .accessibilityLabel("Today by application")
                legend(day.timeline).padding(.horizontal, 14).padding(.top, 5).padding(.bottom, 8)
                Divider()
            }
            if day.timeline.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if model.screenMode != .allDay { hint }
                        ForEach(day.timeline.rows) { row in
                            DayRow(row: row, start: day.start, color: color(rowKey(row), day.timeline), subtitle: subtitle(row)) { open(row, day: day.start) }
                        }
                    }.padding(.horizontal, 6).padding(.vertical, 6)
                }
            }
        }
    }

    private func rowKey(_ row: DayTimeline.Row) -> String {
        if case .app(let bundleID) = row.kind { return bundleID ?? row.title }
        return ""
    }

    private func subtitle(_ row: DayTimeline.Row) -> String {
        switch row.kind {
        case .app:
            guard let first = row.windows.first else { return "" }
            return row.windows.count > 1 ? "\(first), +\(row.windows.count - 1) \(row.windows.count == 2 ? "window" : "windows")" : first
        case .meeting(let id):
            var parts = [row.current ? "Recording now" : "Meeting"]
            if !row.current, model.library.first(where: { $0.id == id })?.vaultPath != nil { parts.append("note saved") }
            if let window = row.windows.first { parts.append("on screen: " + window) }
            return parts.joined(separator: " · ")
        }
    }

    private func open(_ row: DayTimeline.Row, day: Date) {
        switch row.kind {
        case .meeting(let id): model.selectedID = id
        case .app: ScreenHistoryWindow.open(model: model, day: ScreenDayStore.day(day).id, seconds: row.start)
        }
    }

    private func legend(_ timeline: DayTimeline) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(timeline.totals.prefix(3))) { total in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(color(total.key, timeline)).frame(width: 7, height: 7)
                    Text("\(total.app) \(DayTimeline.length(total.seconds))").lineLimit(1)
                }
            }
            if timeline.totals.count > 3 { Text("\(timeline.totals.count - 3) more").foregroundStyle(.tertiary).lineLimit(1) }
            Spacer(minLength: 0)
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private var hint: some View {
        Text(model.screenMode == .off ? "Screen reading is off, so the day shows meetings only."
             : "The screen is read only during meetings, so the day shows meetings only.")
            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.bottom, 4)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing yet today").font(.headline)
            Text(model.screenMode == .allDay
                 ? "As you work, the apps you use and the meetings you record appear here. Their text stays on this Mac."
                 : "Meetings you record appear here. Turn on screen reading above to see your day by application too.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 14).padding(.top, 12)
    }
}

/// The day from its first hour to now: each app's stretches in its colour, and a line above for meetings.
private struct DayStrip: View {
    let timeline: DayTimeline
    let color: (String) -> Color

    var body: some View {
        Canvas { context, size in
            let span = max(1, timeline.to - timeline.from)
            func x(_ time: Double) -> CGFloat { CGFloat((min(max(time, timeline.from), timeline.to) - timeline.from) / span) * size.width }
            let bar = CGRect(x: 0, y: 6, width: size.width, height: 14)
            context.fill(Path(roundedRect: bar, cornerRadius: 4), with: .color(.primary.opacity(0.07)))
            context.clip(to: Path(roundedRect: bar.insetBy(dx: 0, dy: -6), cornerRadius: 4))
            for segment in timeline.segments {
                let rect = CGRect(x: x(segment.start), y: bar.minY, width: max(1.5, x(segment.end) - x(segment.start)), height: bar.height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(color(segment.key).opacity(0.9)))
            }
            for meeting in timeline.meetings {
                let rect = CGRect(x: x(meeting.start), y: 0, width: max(3, x(meeting.end) - x(meeting.start)), height: 3)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(.teal))
            }
        }
        .frame(height: 20)
        .overlay(alignment: .bottom) { hours.offset(y: 13) }
        .padding(.bottom, 13)
    }

    /// Whole hours under the strip, and "now" at its end.
    private var hours: some View {
        Canvas { context, size in
            let span = max(1, timeline.to - timeline.from)
            let first = Int((timeline.from / 3600).rounded(.up)), last = Int((timeline.to / 3600).rounded(.down))
            let step = max(1, Int((Double(last - first + 1) / 7).rounded(.up)))
            let nowLabel = context.resolve(Text("now").font(.system(size: 9)).foregroundStyle(.secondary))
            let nowWidth = nowLabel.measure(in: size).width
            context.draw(nowLabel, at: CGPoint(x: size.width, y: 0), anchor: .topTrailing)
            guard first <= last else { return }
            for hour in stride(from: first, through: last, by: step) {
                let at = CGFloat((Double(hour) * 3600 - timeline.from) / span) * size.width
                let label = context.resolve(Text("\(hour % 12 == 0 ? 12 : hour % 12)").font(.system(size: 9)).foregroundStyle(.tertiary))
                let width = label.measure(in: size).width
                // Not on top of "now".
                guard at + width < size.width - nowWidth - 4 else { continue }
                context.draw(label, at: CGPoint(x: at, y: 0), anchor: .topLeading)
            }
        }
        .frame(height: 11)
        .accessibilityHidden(true)
    }
}

private struct DayRow: View {
    let row: DayTimeline.Row
    let start: Date
    let color: Color
    let subtitle: String
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 8) {
                Text(row.current ? "Now" : start.addingTimeInterval(row.start).formatted(date: .omitted, time: .shortened))
                    .font(.caption2).monospacedDigit().fontWeight(row.current ? .semibold : .regular)
                    .foregroundStyle(row.current ? AnyShapeStyle(Color.teal) : AnyShapeStyle(.tertiary))
                    .frame(width: 50, alignment: .leading).padding(.top, 3)
                icon.frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(row.title).font(.callout.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(DayTimeline.length(row.seconds)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(background, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(row.isMeeting ? "Open this meeting" : "Open what was read here")
        .accessibilityLabel("\(row.title), \(DayTimeline.length(row.seconds))\(subtitle.isEmpty ? "" : ", " + subtitle)")
    }

    private var background: Color {
        if row.isMeeting { return Color.teal.opacity(hovering ? 0.16 : 0.09) }
        return hovering ? Color.primary.opacity(0.06) : .clear
    }

    @ViewBuilder private var icon: some View {
        switch row.kind {
        case .meeting:
            Image(systemName: "waveform").font(.system(size: 11, weight: .semibold)).foregroundStyle(.teal)
                .frame(width: 20, height: 20).background(Color.teal.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
        case .app(let bundleID):
            if let image = AppIcons.icon(bundleID) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Text(row.title.prefix(1).uppercased()).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 20, height: 20).background(color, in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }
}

/// An app's own icon, looked up once.
@MainActor enum AppIcons {
    private static var known: [String: NSImage] = [:]
    private static var missing: Set<String> = []

    static func icon(_ bundleID: String?) -> NSImage? {
        guard let bundleID, !missing.contains(bundleID) else { return nil }
        if let image = known[bundleID] { return image }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { missing.insert(bundleID); return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        known[bundleID] = image
        return image
    }
}

// MARK: - Ask

/// The answer to the question in the box, and which kind of source it was asked of.
struct AskResults: View {
    @ObservedObject var ask: AskService
    let conversationID: String
    let scope: AskScope
    let open: (WorkScribeLink) -> Void
    let rescope: (AskScope) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                ForEach(AskScope.allCases) { item in
                    Button(item.label) { rescope(item) }
                        .buttonStyle(.plain).font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(item == scope ? Color.teal.opacity(0.2) : Color.primary.opacity(0.06), in: Capsule())
                        .foregroundStyle(item == scope ? AnyShapeStyle(Color.teal) : AnyShapeStyle(.secondary))
                        .accessibilityAddTraits(item == scope ? .isSelected : [])
                }
                Spacer(minLength: 4)
                if ask.working.contains(conversationID) { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let answer = ask.conversation(conversationID)?.messages.last(where: { $0.role == .assistant }) {
                        AnswerView(message: answer, open: open, compact: true)
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Footer

/// What stays on this Mac, who writes the notes, and the way to everything else.
struct PopoverFooter<Settings: View>: View {
    @ObservedObject var model: AppModel
    let openWindow: (() -> Void)?
    @ViewBuilder var settings: Settings
    @State private var codex = CodexStatus.current

    var body: some View {
        HStack(spacing: 10) {
            Label(kept, systemImage: "lock").labelStyle(.titleAndIcon)
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                .help("Audio is never stored. Transcripts, notes and screen text are kept on this Mac. Codex receives a note or question and the excerpts found for it.")
            Spacer(minLength: 6)
            codexState
            if let openWindow {
                Button(action: openWindow) { Image(systemName: "macwindow.on.rectangle") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Keep open in a floating window").accessibilityLabel("Open in a floating window")
            }
            settings
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .onReceive(NotificationCenter.default.publisher(for: .workScribeCodexChanged)) { _ in codex = CodexStatus.current }
        .onAppear { codex = CodexStatus.current }
    }

    private var kept: String {
        if model.phase == "recording" { return "Audio is never stored" }
        guard model.screenMode == .allDay else { return "Kept on this Mac" }
        switch model.screenHistoryDays {
        case 0: return "Kept on this Mac · screen until you delete it"
        case 1: return "Kept on this Mac · screen for today"
        case let days: return "Kept on this Mac · screen for \(days) days"
        }
    }

    @ViewBuilder private var codexState: some View {
        if codex.usable {
            Label("Codex", systemImage: "checkmark").labelStyle(.titleAndIcon)
                .font(.caption2).foregroundStyle(.green).help(codex.summary)
        } else if !codex.installed {
            Text("Codex not installed").font(.caption2).foregroundStyle(.orange).help(codex.summary)
        } else if case .signingIn = codex.account {
            Text("Finish signing in…").font(.caption2).foregroundStyle(.secondary)
        } else {
            Button("Sign in to Codex…") { Task { await CodexAppServer.shared.signIn() } }
                .controlSize(.mini).help(codex.summary + " Recording, transcripts and search keep working.")
        }
    }
}
