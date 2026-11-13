import SwiftUI
import WorkScribeCore

/// Settings › Codex: who is signed in, and the one thing to do about it.
struct CodexSettingsSection: View {
    @State private var status = CodexStatus.current

    var body: some View {
        Section("AI lines, titles and answers") {
            Text(status.summary)
            if !status.installed {
                Button("Look for Codex again") { Task { await CodexAppServer.shared.start(); status = CodexStatus.current } }
            } else if case .unsafe = status.process {
                Button("Try Codex again") { Task { await CodexAppServer.shared.reset(); await CodexAppServer.shared.start() } }
            } else {
                switch status.account {
                case .signedIn:
                    Button(CodexInstall.usesEverydaySignIn ? "Stop using Codex" : "Sign out of Codex") { Task { await CodexAppServer.shared.signOut() } }
                case .signingIn: Button("Cancel sign-in") { Task { await CodexAppServer.shared.cancelSignIn() } }
                case .signedOut: Button("Use Codex…") { Task { await CodexAppServer.shared.signIn() } }
                case .unknown:
                    if !CodexInstall.hasCredentials { Button("Use Codex…") { Task { await CodexAppServer.shared.signIn() } } }
                }
            }
            Text("Codex receives the note or question and the excerpts found for it. Audio, the full transcript and your vault stay on this Mac.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .workScribeCodexChanged)) { _ in status = CodexStatus.current }
        .onAppear { status = CodexStatus.current; Task { await CodexAppServer.shared.start() } }
    }
}
