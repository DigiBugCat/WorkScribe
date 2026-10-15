import Foundation

/// A native recognizer cannot always be cancelled mid-call. Release the lifecycle wait
/// if it stops making progress; its late callbacks are fenced by the recording generation.
@MainActor enum RecordingDeadline {
    struct Stalled: Error {}
    static func wait(stall: TimeInterval, progress: @escaping () -> Double = { 0 },
                     operation: @escaping @MainActor () async throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var settled = false
            var worker: Task<Void, Never>?
            var watchdog: Task<Void, Never>?
            func complete(_ result: Result<Void, Error>) {
                guard !settled else { return }
                settled = true
                worker?.cancel(); watchdog?.cancel()
                continuation.resume(with: result)
            }
            worker = Task {
                do { try await operation(); complete(.success(())) }
                catch { complete(.failure(error)) }
            }
            watchdog = Task {
                var last = progress(), changed = Date()
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: UInt64(max(0.01, min(stall / 4, 1)) * 1_000_000_000)) }
                    catch { return }
                    let current = progress()
                    if current != last { last = current; changed = Date() }
                    if Date().timeIntervalSince(changed) >= stall { complete(.failure(Stalled())); return }
                }
            }
        }
    }
}
