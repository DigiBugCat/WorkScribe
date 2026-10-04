import SwiftUI
import AppKit
import WorkScribePlaud

/// Saves everything on a Note Pro to this Mac, then releases it to the Plaud
/// iPhone app. Runs in its own window: downloads can take many minutes.
struct PlaudHandoffView: View {
    @ObservedObject var device: PlaudHandoffController
    @ObservedObject var model: AppModel
    let close: () -> Void
    @State private var confirmRelease = false
    @State private var lastStep = 1
    @State private var clientID = ""
    @State private var secret = ""

    private static let steps = ["Find", "Save to Mac", "Release", "Pair on iPhone"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Save & release Note Pro").font(.title3.weight(.semibold))
                Text("Copies every recording to this Mac, then clears the recorder so it can pair with the Plaud iPhone app.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            stepper
            Group { content }
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Divider()
            HStack {
                Label("Copies stay on this Mac. Nothing is uploaded.", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if device.busy && device.phase != "releasing" {
                    Button("Stop") { device.cancelPreparation() }
                } else {
                    Button("Done") { close() }.keyboardShortcut(.cancelAction).disabled(device.busy)
                }
            }
        }
        .padding(22).frame(width: 460, height: 520)
        .onChange(of: device.phase) { _, phase in
            if let step = Self.step(for: phase) { lastStep = step }
        }
        .confirmationDialog("Release and clear this Note Pro?", isPresented: $confirmRelease, titleVisibility: .visible) {
            Button("Release and clear", role: .destructive) { device.release() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("All \(device.totalCount) recordings are saved on this Mac. This erases them from the recorder and unpairs it from WorkScribe. You can’t undo this.")
        }
    }

    // MARK: Steps

    static func step(for phase: String) -> Int? {
        switch phase {
        case "idle", "signIn", "signingIn", "scanning", "choose": return 1
        case "connecting", "saving": return 2
        case "ready", "releasing", "releaseRetry": return 3
        case "released": return 4
        default: return nil
        }
    }
    private var current: Int { Self.step(for: device.phase) ?? lastStep }
    private var failed: Bool { device.phase == "error" || device.phase == "releaseRetry" }

    private var stepper: some View {
        HStack(spacing: 0) {
            ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, title in
                let number = index + 1
                let done = number < current || (number == 4 && device.phase == "released")
                let active = number == current && !done
                VStack(spacing: 5) {
                    ZStack {
                        Circle().fill(done ? Color.teal : active ? (failed ? Color.orange : Color.teal).opacity(0.18) : Color.primary.opacity(0.07))
                            .frame(width: 26, height: 26)
                        if done { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white) }
                        else if active && failed { Image(systemName: "exclamationmark").font(.caption.weight(.bold)).foregroundStyle(.orange) }
                        else { Text("\(number)").font(.caption.weight(.semibold)).foregroundStyle(active ? Color.teal : .secondary) }
                    }
                    Text(title).font(.caption2.weight(active ? .semibold : .regular))
                        .foregroundStyle(active || done ? .primary : .secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Step \(number), \(title)\(done ? ", done" : active ? ", current" : "")")
                if number < 4 {
                    Rectangle().fill(number < current ? Color.teal : Color.primary.opacity(0.12))
                        .frame(height: 2).frame(maxWidth: 28).offset(y: -9)
                }
            }
        }
    }

    // MARK: Step content

    @ViewBuilder private var content: some View {
        switch device.phase {
        case "signIn", "signingIn": signIn
        case "idle", "scanning", "choose": find
        case "connecting":
            busyLine("Connecting securely…", detail: "This takes a few seconds.")
        case "saving": saving
        case "ready": ready
        case "releasing":
            busyLine("Releasing Note Pro…", detail: "Keep it close until this finishes.")
        case "releaseRetry":
            panel(tint: .red, icon: "exclamationmark.octagon.fill", title: "Release isn’t finished") {
                Text(device.status).font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("Your saved copies are safe. The recorder may not pair with Plaud until this succeeds.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Retry release") { device.release() }.buttonStyle(.borderedProminent).tint(.red)
            }
        case "released": released
        default:
            panel(tint: .orange, icon: "exclamationmark.triangle.fill", title: "That didn’t work") {
                Text(device.status).font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("Nothing was cleared from the Note Pro.").font(.caption).foregroundStyle(.secondary)
                Button("Try again") { device.scan() }.buttonStyle(.borderedProminent).tint(.teal)
            }
        }
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sign in to Plaud").font(.headline)
            Text(device.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Client ID", text: $clientID).textFieldStyle(.roundedBorder)
            SecureField("Client secret", text: $secret).textFieldStyle(.roundedBorder).onSubmit(submitSignIn)
            HStack {
                Button("Sign in and find Note Pro", action: submitSignIn)
                    .buttonStyle(.borderedProminent).tint(.teal)
                    .disabled(device.phase == "signingIn" || clientID.isEmpty || secret.isEmpty)
                if device.phase == "signingIn" { ProgressView().controlSize(.small) }
            }
            Text("Sent only to Plaud. The secret isn’t saved; the 24-hour session is kept in this Mac’s Keychain. You sign in as the same Plaud user that paired this Note Pro.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func submitSignIn() {
        guard !clientID.isEmpty, !secret.isEmpty else { return }
        let entered = secret; secret = ""
        device.signIn(clientID: clientID, secret: entered)
    }

    private var find: some View {
        VStack(alignment: .leading, spacing: 12) {
            if device.phase == "idle" {
                Text("Press the Note Pro’s button to wake it and keep it close to this Mac.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("Stop any recording on it first. WorkScribe will ask for Keychain access to your Plaud session.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Find Note Pro") { device.scan() }.buttonStyle(.borderedProminent).tint(.teal)
                    .disabled(model.busy)
                if model.busy {
                    Text("Available when WorkScribe isn’t recording.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 8) {
                    if device.phase == "scanning" { ProgressView().controlSize(.small) }
                    Text(device.phase == "scanning" && device.devices.isEmpty ? "Looking for your Note Pro…" : device.status)
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 6) {
                    ForEach(device.devices) { item in
                        HStack {
                            Image(systemName: "waveform.circle.fill").font(.title3).foregroundStyle(.teal)
                            Text(item.name).font(.callout.weight(.medium))
                            Spacer()
                            Button("Save its recordings") { device.prepare(id: item.id) }
                                .buttonStyle(.borderedProminent).tint(.teal).controlSize(.small)
                        }
                        .padding(10).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                if device.phase == "choose" {
                    Button(device.devices.isEmpty ? "Scan again" : "Not listed? Scan again") { device.scan() }
                        .buttonStyle(.link)
                }
            }
        }
    }

    private var saving: some View {
        let total = max(device.totalCount, 1)
        let overall = (Double(device.savedCount) + device.fileProgress) / Double(total)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Saving recording \(min(device.savedCount + 1, total)) of \(total)").font(.headline)
            ProgressView(value: overall).tint(.teal)
            HStack {
                Text("\(device.savedCount) saved").font(.caption.monospacedDigit())
                Spacer()
                Text("This recording \(Int(device.fileProgress * 100))%").font(.caption.monospacedDigit())
            }.foregroundStyle(.secondary)
            Text("Keep the Note Pro close. Nothing is cleared until you confirm the release in the next step.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(device.status, systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium)).foregroundStyle(.green)
            if !device.saved.isEmpty { importStatus }
            if let folder = device.backupURL, !device.saved.isEmpty {
                Button("Show saved files") { NSWorkspace.shared.open(folder) }.buttonStyle(.link)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Release the Note Pro").font(.headline)
                Text("Erases the recordings from the recorder and unpairs it from WorkScribe, so you can add it in the Plaud iPhone app. Your copies on this Mac stay.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Release Note Pro…", role: .destructive) { confirmRelease = true }
                    .buttonStyle(.borderedProminent).tint(.red)
            }
        }
    }

    @ViewBuilder private var importStatus: some View {
        if let status = model.importStatus {
            HStack(spacing: 8) {
                if model.importActive { ProgressView().controlSize(.small) }
                else { Image(systemName: "tray.full").foregroundStyle(.secondary) }
                Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var released: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Ready for the Plaud iPhone app", systemImage: "checkmark.circle.fill")
                .font(.headline).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 6) {
                Text("1.  Open Plaud on your iPhone.")
                Text("2.  Tap Add device.")
                Text("3.  Choose Note Pro.")
            }.font(.callout)
            importStatus
            Text("To use it with WorkScribe again: sync it in Plaud, remove it there, then come back here.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Pieces

    private func busyLine(_ title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func panel<Content: View>(tint: Color, icon: String, title: String, @ViewBuilder _ body: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.headline).foregroundStyle(tint)
            body()
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }
}
