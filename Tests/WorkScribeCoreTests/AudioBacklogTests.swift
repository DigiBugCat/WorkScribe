import XCTest
@testable import WorkScribeCore

final class AudioBacklogTests: XCTestCase {
    func testOrderAndInFlightBudgetArePreserved() async throws {
        let backlog = AudioBacklog(seconds: 2)
        let a = Data(repeating: 11, count: 32_000), b = Data(repeating: 22, count: 32_000)
        try backlog.append(a); try backlog.append(b)
        let first = try await backlog.next()
        XCTAssertEqual(first, a)
        // Reading does not release capacity until ASR acknowledges the batch.
        XCTAssertEqual(backlog.pendingSeconds, 2)
        XCTAssertThrowsError(try backlog.append(Data([1, 2]))) { XCTAssertTrue($0 is AudioBacklog.Overflow) }
        backlog.acknowledge(a.count)
        backlog.finish()
        let second = try await backlog.next()
        XCTAssertEqual(second, b)
        backlog.acknowledge(b.count)
        let end = try await backlog.next()
        XCTAssertNil(end); XCTAssertEqual(backlog.pendingSeconds, 0)
    }

    func testErrorDrainsAlreadyAcceptedAudioAndDiscardReleasesBudget() async throws {
        let backlog = AudioBacklog(seconds: 1)
        try backlog.append(Data(repeating: 3, count: 640))
        backlog.finish(throwing: AudioBacklog.Overflow())
        let accepted = try await backlog.next()
        XCTAssertEqual(accepted?.count, 640)
        do { _ = try await backlog.next(); XCTFail("the capture failure must be visible") }
        catch { XCTAssertTrue(error is AudioBacklog.Overflow) }
        backlog.discard()
        XCTAssertEqual(backlog.pendingSeconds, 0)
    }

    func testWaitingConsumerCanBeCancelledWithoutInput() async {
        let backlog = AudioBacklog()
        let consumer = Task { try await backlog.next() }
        consumer.cancel()
        do { _ = try await consumer.value; XCTFail("cancelled consumer should exit") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
