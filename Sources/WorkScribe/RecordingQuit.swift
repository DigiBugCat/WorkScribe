import AppKit

/// One quit transaction. A blocked quit has no shutdown side effects;
/// repeated Apple events join the same save instead of tearing down services twice.
@MainActor final class RecordingQuit {
    private(set) var pending = false
    /// Quitting mid-meeting stops and saves without asking: nothing is lost, so there is nothing to confirm.
    func request(phase: String, blocked: Bool,
                 save: @escaping @MainActor () async -> Void,
                 complete: @escaping @MainActor () -> Void) -> NSApplication.TerminateReply {
        if pending { return .terminateLater }
        if blocked || phase == "starting" { return .terminateCancel }
        pending = true
        Task { await save(); complete() }
        return .terminateLater
    }
}
