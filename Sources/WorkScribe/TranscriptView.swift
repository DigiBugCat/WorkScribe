import SwiftUI
import WorkScribeCore

/// A moment to show in a transcript: a citation or `workscribe://` link. `token` makes a repeat request distinct.
struct TranscriptFocus: Equatable {
    var meetingID: String
    var seconds: Double?
    var segmentID: String?
    var token = UUID()
}

struct TranscriptView: View {
    let meeting: Meeting
    let live: Bool
    @Binding var followLive: Bool
    /// Builds the naming popover for a turn's first segment; the closure dismisses it.
    var editor: ((Segment, @escaping () -> Void) -> AnyView)?
    /// Scrolls to and briefly highlights this moment when it belongs to `meeting`.
    var focus: TranscriptFocus? = nil
    @State private var editingTurn: String?
    @State private var hoveredTurn: String?
    @State private var highlighted: String?

    /// Consecutive segments from the same person read as one turn.
    private struct Turn: Identifiable {
        var segments: [Segment]
        var name: String
        var id: String { segments[0].id }
        var first: Segment { segments[0] }
    }

    private var revision: String {
        (meeting.segments.last?.id ?? "") + meeting.partials.keys.sorted().map { meeting.partials[$0] ?? "" }.joined()
    }
    /// Diarization numbers speakers per source. When the microphone only ever hears
    /// one voice, that voice is almost always the person running the app.
    private var microphoneIsSolo: Bool {
        Set(meeting.segments.filter { $0.source == "microphone" && !$0.speaker.hasSuffix("-0") && !$0.speaker.hasSuffix(":unknown") }.map(\.speaker)).count == 1
    }
    private var bothSources: Bool { Set(meeting.segments.map(\.source)).count > 1 }

    private var turns: [Turn] {
        TranscriptTurns.group(meeting).map { turn in
            Turn(segments: turn.segments, name: displayName(turn.first, solo: microphoneIsSolo))
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(turns) { turn in turnView(turn) }
                    ForEach(meeting.partials.keys.sorted(), id: \.self) { source in
                        if let text = meeting.partials[source], !text.isEmpty { partialView(source: source, text: text) }
                    }
                    if meeting.segments.isEmpty && meeting.partials.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(live ? "Listening…" : "No speech was transcribed.").font(.callout.weight(.medium))
                            if live {
                                Text("Words appear here as people speak. Speaker names fill in as voices are told apart.")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }.padding(.vertical, 12)
                    }
                    Color.clear.frame(height: 1).id("transcript-bottom")
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .modifier(FollowOnScroll(followLive: $followLive, live: live))
            .overlay(alignment: .bottom) {
                if live && !followLive {
                    Button { followLive = true } label: {
                        Label("Jump to live", systemImage: "arrow.down").font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                    }
                    .buttonStyle(.plain).foregroundStyle(.white)
                    .background(.teal, in: Capsule()).shadow(radius: 2, y: 1)
                    .padding(.bottom, 10)
                }
            }
            .onChange(of: revision) { _, _ in if live && followLive { proxy.scrollTo("transcript-bottom", anchor: .bottom) } }
            .onChange(of: followLive) { _, following in if following { withAnimation { proxy.scrollTo("transcript-bottom", anchor: .bottom) } } }
            .onChange(of: meeting.id) { _, _ in if live && followLive { proxy.scrollTo("transcript-bottom", anchor: .bottom) } }
            .onChange(of: focus) { _, _ in show(focus, proxy) }
            .onAppear { show(focus, proxy) }
        }
    }

    /// The turn holding the focused segment, else the last turn starting at or before the time.
    private func show(_ focus: TranscriptFocus?, _ proxy: ScrollViewProxy) {
        guard let focus, focus.meetingID == meeting.id else { return }
        let all = turns
        let target = focus.segmentID.flatMap { id in all.first { $0.segments.contains { $0.id == id } } }
            ?? focus.seconds.flatMap { seconds in all.last { $0.first.start <= seconds + 0.5 } ?? all.first }
        guard let target else { return }
        followLive = false
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(target.id, anchor: .center) }
            highlighted = target.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if highlighted == target.id { withAnimation { highlighted = nil } } }
        }
    }

    private func turnView(_ turn: Turn) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button { editingTurn = turn.id } label: {
                    HStack(spacing: 6) {
                        Circle().fill(color(turn.first)).frame(width: 8, height: 8)
                        Text(turn.name).font(.caption.weight(.semibold)).foregroundStyle(color(turn.first))
                        Image(systemName: "pencil").font(.caption2).foregroundStyle(.secondary)
                            .opacity(hoveredTurn == turn.id || editingTurn == turn.id ? 1 : 0)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Name this speaker")
                .onHover { inside in hoveredTurn = inside ? turn.id : (hoveredTurn == turn.id ? nil : hoveredTurn) }
                .accessibilityLabel("\(turn.name). Name this speaker")
                .disabled(editor == nil)
                .popover(isPresented: Binding(get: { editingTurn == turn.id }, set: { if !$0 { editingTurn = nil } }),
                         arrowEdge: .bottom) {
                    editor?(turn.first) { editingTurn = nil }
                }
                if bothSources {
                    Image(systemName: turn.first.source == "microphone" ? "mic" : "speaker.wave.2")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .help(turn.first.source == "microphone" ? "Microphone" : "System audio")
                }
                Spacer(minLength: 4)
                Text(AppModel.timestamp(turn.first.start)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
            Text(turn.segments.map(\.text).joined(separator: " "))
                .font(.system(size: 14)).lineSpacing(3)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
        .padding(highlighted == turn.id ? 6 : 0)
        .background(highlighted == turn.id ? Theme.indigoWash.opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .id(turn.id)
    }

    private func partialView(source: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "waveform").font(.caption2).foregroundStyle(.teal).symbolEffect(.variableColor.iterative)
                if let speaker = meeting.partialSpeakers?[source], speaker.contains("speaker-"), !speaker.hasSuffix("-0") {
                    let sample = Segment(source: source, speaker: speaker, start: 0, end: 0, text: "")
                    Text(displayName(sample, solo: microphoneIsSolo)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                } else {
                    Text("Transcribing").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(text).font(.system(size: 14)).lineSpacing(3).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func displayName(_ segment: Segment, solo: Bool) -> String {
        if let assigned = meeting.assignment(for: segment) { return assigned.name }
        if let name = meeting.speakerAssignments?[segment.speaker]?.name, !name.isEmpty { return name }
        let original = Meeting.originalSpeakerName(segment.speaker)
        guard segment.source == "microphone", original != "Unidentified speaker" else { return original }
        return solo ? "You" : "Mic · \(original)"
    }

    private func color(_ segment: Segment) -> Color {
        guard let number = segment.speaker.components(separatedBy: "speaker-").last.flatMap(Int.init), number > 0 else { return .secondary }
        if segment.source == "microphone" && microphoneIsSolo { return .teal }
        let palette: [Color] = [.purple, .orange, .blue, .pink, .green, .indigo, .mint, .brown]
        return palette[(number - 1 + (segment.source == "microphone" ? 4 : 0)) % palette.count]
    }
}

/// Scrolling up pauses live following; scrolling back to the end resumes it.
/// Only the person's own scrolling counts, not the automatic scroll to new words.
private struct FollowOnScroll: ViewModifier {
    @Binding var followLive: Bool
    let live: Bool
    @State private var userScrolling = false
    @State private var atBottom = true

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .onScrollPhaseChange { _, phase in
                    let wasUser = userScrolling
                    userScrolling = phase == .interacting || phase == .tracking || phase == .decelerating
                    if live && wasUser && !userScrolling { followLive = atBottom }
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 32
                } action: { _, bottom in
                    atBottom = bottom
                    if live && userScrolling { followLive = bottom }
                }
        } else {
            content
        }
    }
}
