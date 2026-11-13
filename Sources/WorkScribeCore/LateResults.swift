import Foundation

/// Work whose result is wanted now but is not worth waiting long for.
///
/// A caller asks for the result of some work on a slot and waits at most `wait` seconds. If the work
/// takes longer the caller goes on without it; the work carries on, and its result is handed, once,
/// to the next caller that asks `late` for the same slot and tag. One piece of work runs per slot.
///
/// The screen reader uses it for a window's picture vector. The text of a window must not wait for
/// the vision model, which can take a minute to load, and must not be thrown away because it did:
/// a reading that comes back after the person has moved on is dropped (`ScreenWatch`, Return).
public final class LateResults<Value: Sendable>: @unchecked Sendable {
    private struct Arrived { var tag: String?; var at: Double; var value: Value }
    private final class Claim: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        /// True for the first caller only.
        func take() -> Bool { lock.withLock { if taken { return false }; taken = true; return true } }
    }

    private let lock = NSLock()
    private var running: [Int32: Int] = [:]
    private var arrived: [Int32: Arrived] = [:]
    private var generation = 0

    public init() {}

    public func isRunning(slot: Int32) -> Bool { lock.withLock { running[slot] != nil } }

    /// Starts `work` on `slot`, unless work is already running there, and returns its result if it comes
    /// within `wait` seconds. `tag` names what the work is about (a window's title) and `at` is when that
    /// was seen; a result that comes later is kept under them for `late`.
    public func run(slot: Int32, tag: String?, at: Double, wait: Double, work: @escaping @Sendable () async -> Value?) async -> Value? {
        let started: Int? = lock.withLock {
            guard running[slot] == nil else { return nil }
            generation += 1; running[slot] = generation; arrived[slot] = nil
            return generation
        }
        guard let started else { return nil }
        let claim = Claim()
        return await withCheckedContinuation { (done: CheckedContinuation<Value?, Never>) in
            Task.detached(priority: .utility) { [self] in
                let value = await work()
                let inTime = claim.take()
                // Cleared while it ran: nobody may have the result.
                let current: Bool = lock.withLock {
                    guard running[slot] == started else { return false }
                    running[slot] = nil
                    if !inTime, let value { arrived[slot] = Arrived(tag: tag, at: at, value: value) }
                    return true
                }
                if inTime { done.resume(returning: current ? value : nil) }
            }
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
                if claim.take() { done.resume(returning: nil) }
            }
        }
    }

    /// A result that came after its caller stopped waiting, if it is about the same thing (`tag`) and was
    /// seen no longer than `maxAge` seconds before `at`. It is handed out once; a result about something
    /// else, or an old one, is dropped.
    public func late(slot: Int32, tag: String?, at: Double, maxAge: Double) -> Value? {
        lock.withLock {
            guard let ready = arrived[slot] else { return nil }
            arrived[slot] = nil
            guard ready.tag == tag, at >= ready.at, at - ready.at <= maxAge else { return nil }
            return ready.value
        }
    }

    /// Forgets everything: work still running finishes, and its result goes to nobody.
    public func clear() { lock.withLock { running.removeAll(); arrived.removeAll() } }
}
