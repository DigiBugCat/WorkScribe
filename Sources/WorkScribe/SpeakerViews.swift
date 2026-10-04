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
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var profileID: String?
    @State private var wholeSpeaker = true
    @State private var remember = true
    private var entry: Meeting? { model.latestMeeting(target.meetingID) }
    private var knownSpeaker: Bool { target.segment.speaker.contains(":speaker-") && !target.segment.speaker.hasSuffix("-0") }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Name speaker").font(.headline)
            Text(target.segment.text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineLimit(3)
            TextField("Speaker name", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            if let suggestion = entry?.speakerSuggestions?[target.segment.speaker],
               let profile = model.voices.first(where: { $0.id == suggestion.profileID }) {
                Button("Suggested: \(profile.name)") { name = profile.name; profileID = profile.id }
                    .font(.caption)
            }
            if !model.voices.isEmpty {
                Menu("Choose a remembered person") {
                    ForEach(model.voices) { voice in
                        Button(voice.name) { name = voice.name; profileID = voice.id }
                    }
                }
            }
            Picker("Apply to", selection: $wholeSpeaker) {
                Text("This segment").tag(false)
                Text("All segments from this speaker").tag(true)
            }.pickerStyle(.radioGroup).disabled(!knownSpeaker)
            Toggle("Remember this voice on this Mac", isOn: $remember).font(.callout)
            Text("Learns from clear speech after recording ends. Future matches appear as suggestions for you to confirm.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if entry?.sourceOffsets == nil {
                Text("This older recording can be named, but cannot supply aligned voice samples.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(model.voiceStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            HStack {
                Button("Restore label") {
                    model.clearSpeaker(meetingID: target.meetingID, segmentID: target.segment.id, wholeSpeaker: wholeSpeaker)
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 360)
            .onAppear {
                if let assignment = entry?.assignment(for: target.segment) {
                    name = assignment.name; profileID = assignment.profileID; remember = assignment.remember
                }
                wholeSpeaker = knownSpeaker && entry?.segmentAssignments?[target.segment.id] == nil
            }
    }
    private func save() {
        let selected = model.voices.first { $0.id == profileID && $0.name == name }?.id
        if model.nameSpeaker(meetingID: target.meetingID, segmentID: target.segment.id, name: name,
                             profileID: selected, wholeSpeaker: wholeSpeaker, remember: remember) { dismiss() }
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
