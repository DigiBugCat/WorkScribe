import XCTest
import WorkScribeCore
@testable import WorkScribe

/// Asking a second question in a conversation cancels the first. The first, as it winds down, must
/// not clear the second's bookkeeping, and must not be left looking as if it were still being written.
@MainActor final class AskTaskTests: XCTestCase {
    private struct SlowAnswers: AnswerGenerator {
        let displayName = "Slow fixture", provider = "codex", modelName = "fixture", isAvailable = true
        func stream(_ prompt: AskPrompt) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    for word in ["The ", "alert ", "is ", "Dana's [1]."] {
                        try? await Task.sleep(for: .milliseconds(120))
                        if Task.isCancelled { break }
                        continuation.yield(word)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
    private struct OneMoment: AskMomentProvider {
        func moments(for question: String, context: AskContext) async -> [AskMoment] {
            [AskMoment(id: "fixture", sourceKind: "file", ref: "/tmp/notes.md", title: "Notes", kind: "document", start: nil, end: nil,
                       text: "Dana will set up the monthly budget alert today.", snippet: "Dana will set up the alert", attached: true)]
        }
    }

    func testASecondQuestionKeepsItsOwnBookkeepingWhenTheFirstIsCancelled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: MeetingStore(root: root))
        let ask = AskService(model: model, store: ConversationStore(root: root.appendingPathComponent("Chats")), generator: SlowAnswers())
        ask.register(OneMoment())

        let first = ask.ask("who owns the alert?", in: nil)
        try await Task.sleep(for: .milliseconds(200))                    // the first answer is mid-stream
        let second = ask.ask("and when?", in: first.conversation)
        XCTAssertEqual(second.conversation, first.conversation)
        let cut = try XCTUnwrap(ask.conversation(first.conversation)?.messages.first { $0.id == first.message })
        XCTAssertNotEqual(cut.state, .working, "an answer that was cut off does not look as if it were still being written")

        try await Task.sleep(for: .milliseconds(150))                    // the first task has wound down by now
        XCTAssertTrue(ask.working.contains(first.conversation), "the second question is still being answered")
        // The second can still be cancelled: its task is the one on record.
        ask.cancel(first.conversation)
        XCTAssertFalse(ask.working.contains(first.conversation))
        try await Task.sleep(for: .milliseconds(700))
        let after = try XCTUnwrap(ask.conversation(first.conversation)?.messages.first { $0.id == second.message })
        XCTAssertFalse(after.text.contains("Dana's"), "a cancelled answer stops being written")
        XCTAssertNotEqual(after.state, .working)
    }
}
