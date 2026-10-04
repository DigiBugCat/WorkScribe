import SwiftUI
import WorkScribeCore

struct SpeakerEditTarget: Identifiable {
    var meetingID: String
    var segment: Segment
    var id: String { meetingID + segment.id }
}

struct SpeakerNamingView: View {
    @ObservedObject var model: AppModel
    let target: SpeakerEditTarget
    var done: () -> Void = {}
    @State private var name = ""
    @State private var profileID: String?
    @State private var onlyThisLine = false
    @State private var remember = false
    @FocusState private var focused: Bool
    private var entry: Meeting? { model.latestMeeting(target.meetingID) }
    private var knownSpeaker: Bool { target.segment.speaker.contains(":speaker-") && !target.segment.speaker.hasSuffix("-0") }
    private var original: String { Meeting.originalSpeakerName(target.segment.speaker) }
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// A remembered person already agreed to voice matching; a new name has to opt in.
    private var chosenProfile: VoiceProfile? {
        model.voices.first { $0.id == profileID && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
            ?? model.voices.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }
    private var completions: [VoiceProfile] {
        let typed = trimmed
        return model.voices.filter { typed.isEmpty || ($0.name.localizedCaseInsensitiveContains(typed) && $0.name.caseInsensitiveCompare(typed) != .orderedSame) }
            .prefix(4).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(knownSpeaker ? "Who is \(original)?" : "Who said this?").font(.headline)
            if let suggestion = entry?.speakerSuggestions?[target.segment.speaker], trimmed.isEmpty {
                Button { pick(suggestion.profileID, suggestion.name) } label: {
                    Label("Sounds like \(suggestion.name)", systemImage: "person.wave.2")
                }.buttonStyle(.borderless).font(.callout)
            }
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).focused($focused).onSubmit(save)
            if !completions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(completions) { voice in
                        Button { pick(voice.id, voice.name) } label: {
                            Label(voice.name, systemImage: "person.crop.circle").frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.borderless).font(.callout)
                    }
                }
            }
            if knownSpeaker {
                Toggle("Only this line", isOn: $onlyThisLine).font(.callout)
            }
            if let chosen = chosenProfile, !trimmed.isEmpty {
                Label("Matches future recordings using \(chosen.name)’s remembered voice", systemImage: "checkmark.seal")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if !trimmed.isEmpty {
                Toggle(isOn: $remember) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Remember \(trimmed)’s voice").font(.callout)
                        Text("Kept on this Mac to suggest them in future recordings.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                if entry.flatMap({ $0.assignment(for: target.segment) }) != nil {
                    Button("Restore \(original)") {
                        model.clearSpeaker(meetingID: target.meetingID, segmentID: target.segment.id, wholeSpeaker: !onlyThisLine)
                        done()
                    }.buttonStyle(.borderless)
                }
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(trimmed.isEmpty)
            }
        }
        .padding(16).frame(width: 290)
        .onAppear {
            if let assignment = entry?.assignment(for: target.segment) {
                name = assignment.name; profileID = assignment.profileID; remember = assignment.remember
            }
            onlyThisLine = !knownSpeaker || entry?.segmentAssignments?[target.segment.id] != nil
            focused = true
        }
    }
    private func pick(_ id: String, _ value: String) { name = value; profileID = id }
    private func save() {
        guard !trimmed.isEmpty else { return }
        let profile = chosenProfile
        if model.nameSpeaker(meetingID: target.meetingID, segmentID: target.segment.id, name: trimmed,
                             profileID: profile?.id, wholeSpeaker: knownSpeaker && !onlyThisLine,
                             remember: profile != nil || remember) { done() }
    }
}

struct RememberedVoicesView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editingID: String?
    @State private var editedName = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remembered voices").font(.headline)
            Text("Names and voice samples stay on this Mac. Renaming affects future labels; forgetting keeps names already saved in transcripts.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.voices.isEmpty {
                Text("Click a speaker label in a transcript to name someone and remember their voice.")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(model.voices) { voice in
                            HStack {
                                if editingID == voice.id {
                                    TextField("Name", text: $editedName).textFieldStyle(.roundedBorder)
                                    Button("Save") { model.renameVoice(id: voice.id, name: editedName); editingID = nil }
                                } else {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(voice.name).font(.callout.weight(.medium))
                                        Text(voice.samples.isEmpty ? "Waiting for clear speech" : "\(voice.samples.count) confirmed voice samples").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer()
                                    Button { editingID = voice.id; editedName = voice.name } label: { Image(systemName: "pencil") }.help("Rename voice")
                                    Button("Forget") { model.forgetVoice(id: voice.id) }
                                }
                            }
                        }
                    }
                }.frame(maxHeight: 220)
            }
            Text(model.voiceStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 360)
    }
}
