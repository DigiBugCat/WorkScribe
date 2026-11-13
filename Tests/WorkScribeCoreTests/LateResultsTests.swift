import XCTest
@testable import WorkScribeCore

/// A window's text must not wait for the vector of its picture, and the vector must not be lost because the text
/// did not wait: `LateResults` is the piece that makes both true.
final class LateResultsTests: XCTestCase {
    /// Work that finishes when the test says so.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        private var count = 0
        var started: Int { lock.withLock { count } }
        func pass() async {
            await withCheckedContinuation { (next: CheckedContinuation<Void, Never>) in
                let go: Bool = lock.withLock { count += 1; if isOpen { return true }; waiting.append(next); return false }
                if go { next.resume() }
            }
        }
        func open() {
            let held: [CheckedContinuation<Void, Never>] = lock.withLock { isOpen = true; defer { waiting = [] }; return waiting }
            held.forEach { $0.resume() }
        }
    }

    private func settle(_ results: LateResults<Int>, slot: Int32) async {
        for _ in 0..<200 where results.isRunning(slot: slot) { try? await Task.sleep(nanoseconds: 10_000_000) }
        // The result is stored in the same step that ends the work; one more turn lets a cleared run finish too.
        try? await Task.sleep(nanoseconds: 30_000_000)
    }

    func testAResultThatIsReadyInTimeIsReturnedAndNotKeptForLater() async {
        let results = LateResults<Int>()
        let value = await results.run(slot: 1, tag: "Roadmap.key", at: 10, wait: 5) { 7 }
        XCTAssertEqual(value, 7)
        XCTAssertFalse(results.isRunning(slot: 1))
        XCTAssertNil(results.late(slot: 1, tag: "Roadmap.key", at: 11, maxAge: 60), "it was already handed over")
    }

    func testTheCallerGoesOnWithoutSlowWorkAndTheNextCallerGetsItsResultOnce() async {
        let results = LateResults<Int>(), gate = Gate()
        let began = Date()
        let value = await results.run(slot: 1, tag: "Roadmap.key", at: 10, wait: 0.05) { await gate.pass(); return 7 }
        XCTAssertNil(value, "the caller did not wait for it")
        XCTAssertLessThan(Date().timeIntervalSince(began), 2, "and was not held up")
        XCTAssertTrue(results.isRunning(slot: 1), "the work carries on")
        XCTAssertNil(results.late(slot: 1, tag: "Roadmap.key", at: 11, maxAge: 60), "nothing has arrived yet")
        gate.open()
        await settle(results, slot: 1)
        XCTAssertEqual(results.late(slot: 1, tag: "Roadmap.key", at: 12, maxAge: 60), 7)
        XCTAssertNil(results.late(slot: 1, tag: "Roadmap.key", at: 13, maxAge: 60), "handed out once")
    }

    func testALateResultAboutAnotherWindowIsDroppedNotKept() async {
        let results = LateResults<Int>(), gate = Gate()
        _ = await results.run(slot: 1, tag: "Bank statement", at: 10, wait: 0.02) { await gate.pass(); return 7 }
        gate.open()
        await settle(results, slot: 1)
        XCTAssertNil(results.late(slot: 1, tag: "Roadmap.key", at: 12, maxAge: 60), "a picture of one window is not another window's")
        XCTAssertNil(results.late(slot: 1, tag: "Bank statement", at: 13, maxAge: 60), "and it is gone")
    }

    func testALateResultThatIsTooOldIsDropped() async {
        let results = LateResults<Int>(), gate = Gate()
        _ = await results.run(slot: 1, tag: "Roadmap.key", at: 10, wait: 0.02) { await gate.pass(); return 7 }
        gate.open()
        await settle(results, slot: 1)
        XCTAssertNil(results.late(slot: 1, tag: "Roadmap.key", at: 71, maxAge: 60))
    }

    func testOnePieceOfWorkRunsPerSlot() async {
        let results = LateResults<Int>(), gate = Gate()
        _ = await results.run(slot: 1, tag: "a", at: 10, wait: 0.02) { await gate.pass(); return 1 }
        let second = await results.run(slot: 1, tag: "a", at: 11, wait: 0.02) { await gate.pass(); return 2 }
        XCTAssertNil(second)
        XCTAssertEqual(gate.started, 1, "the second was not started while the first runs")
        let elsewhere = await results.run(slot: 2, tag: "b", at: 11, wait: 5) { 3 }
        XCTAssertEqual(elsewhere, 3, "another app's picture is its own work")
        gate.open()
        await settle(results, slot: 1)
        XCTAssertEqual(results.late(slot: 1, tag: "a", at: 12, maxAge: 60), 1)
    }

    func testNothingIsHandedOutAfterClear() async {
        let results = LateResults<Int>(), gate = Gate()
        _ = await results.run(slot: 1, tag: "a", at: 10, wait: 0.02) { await gate.pass(); return 1 }
        results.clear()
        XCTAssertFalse(results.isRunning(slot: 1))
        gate.open()
        await settle(results, slot: 1)
        XCTAssertNil(results.late(slot: 1, tag: "a", at: 12, maxAge: 60), "reading stopped: its result goes to nobody")
    }

    func testWorkThatFindsNothingLeavesNothing() async {
        let results = LateResults<Int>(), gate = Gate()
        _ = await results.run(slot: 1, tag: "a", at: 10, wait: 0.02) { await gate.pass(); return nil }
        gate.open()
        await settle(results, slot: 1)
        XCTAssertNil(results.late(slot: 1, tag: "a", at: 12, maxAge: 60))
        let again = await results.run(slot: 1, tag: "a", at: 13, wait: 5) { 4 }
        XCTAssertEqual(again, 4, "and the slot is free again")
    }
}
