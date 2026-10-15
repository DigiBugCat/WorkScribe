import AppKit

/// One quit transaction. Cancelling the dialog has no shutdown side effects;
/// repeated Apple events join the same save instead of tearing down services twice.
@MainActor final class RecordingQuit {
    private(set) var pending = false
    func request(phase: String, blocked: Bool, confirm: () -> Bool,
                 save: @escaping @MainActor () async -> Void,
                 complete: @escaping @MainActor () -> Void) -> NSApplication.TerminateReply {
        if pending { return .terminateLater }
        if blocked || phase == "starting" { return .terminateCancel }
        if phase == "recording" && !confirm() { return .terminateCancel }
        pending = true
        Task { await save(); complete() }
        return .terminateLater
    }
}
