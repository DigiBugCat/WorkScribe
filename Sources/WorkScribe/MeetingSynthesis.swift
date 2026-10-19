import Foundation
import WorkScribeCore

struct MeetingSummary: Sendable {
    var topics: [MissedTopic]
    var actions: [ActionItem]
}
/// Optional work after line settlement. It never rewrites or owns line state.
struct MeetingSynthesis {
    let model: any TextModel
    /// Optional meeting synthesis is separate from the line lifecycle and reads uncovered evidence.
    func afterStop(_ meeting: Meeting) async throws -> MeetingSummary? {
        let uncovered = UncoveredDiscussion.excerpts(meeting)
        guard !uncovered.isEmpty, model.isAvailable else { return nil }
        let commitments = Commitments.find(Chunker.transcript(meeting))
        let rephrases = commitments.filter(Commitments.needsRephrasing).count
        let topicCalls = max(1, EngineConstants.synthesisCalls - rephrases)
        let windowSize = max(8, (uncovered.count + topicCalls - 1) / topicCalls)
        var calls = 0, topics: [Bullet] = []
        for start in stride(from: 0, to: uncovered.count, by: windowSize) {
            try Task.checkCancellation()
            var window = Array(uncovered[start..<min(start + windowSize, uncovered.count)])
            let notes = (meeting.notes ?? []).map(\.shorthand)
            while !window.isEmpty, try !EvidenceBudget.synthesisFits(NotePrompt.topics(window, notes: notes)) { window.removeLast() }
            guard !window.isEmpty else { continue }
            calls += 1
            let generated = try await model.generate(TextRequest(NotePrompt.topics(window, notes: notes), cacheablePrefix: NotePrompt.topicsHead, maxTokens: 500, stop: NotePrompt.endMarker))
            topics += groundedTopics(generated.text, excerpts: window).filter { bullet in
                Grounding.supported(bullet.text, evidence: window.filter { bullet.refs.contains($0.id) }.map(\.chunk.text))
            }
        }
        topics = NoteOutput.balancedTopics(topics, excerpts: uncovered)
        var actions: [ActionItem] = []
        for candidate in commitments {
            try Task.checkCancellation()
            if !Commitments.needsRephrasing(candidate) || calls >= EngineConstants.synthesisCalls { actions.append(ActionItem(owner: candidate.owner, text: candidate.task)); continue }
            calls += 1
            let generated = try await model.generate(TextRequest(Commitments.rephrasePrompt(candidate), cacheablePrefix: Commitments.rephraseHead, maxTokens: 40))
            actions.append(ActionItem(owner: candidate.owner, text: Commitments.rephrased(generated.text, candidate: candidate)))
        }
        return MeetingSummary(topics: topics.map { bullet in
            MissedTopic(topic: bullet.topic, text: bullet.text, excerptRefs: bullet.refs.compactMap { id in uncovered.first { $0.id == id }?.chunk.id })
        }, actions: NoteOutput.dedupe(actions))
    }
    func brief(_ meeting: Meeting) async -> String? {
        let facts = BriefPolicy.facts(meeting)
        guard !facts.isEmpty, model.isAvailable else { return nil }
        for _ in 0..<2 {
            guard !Task.isCancelled,
                  let result = try? await model.generate(TextRequest(BriefPolicy.prompt(meeting), cacheablePrefix: BriefPolicy.promptHead, maxTokens: 120)) else { return nil }
            if let brief = BriefPolicy.clean(result.text, evidence: facts) { return brief }
        }
        return nil
    }
    func groundedTopics(_ output: String, excerpts: [PromptEvidence]) -> [Bullet] {
        let parsed = NoteOutput.parse(output), allowed = Set(excerpts.map(\.id))
        return (parsed.notes + parsed.missed).compactMap { original in
            var bullet = NoteOutput.withoutPlaceholder(original)
            guard !bullet.topic.isEmpty else { return nil } // a topic list needs topics
            if bullet.refs.isEmpty, let scores = try? LexicalMatcher().similarities(notes: [bullet.topic + " " + bullet.text], chunks: excerpts.map { $0.chunk.text }).first {
                bullet.refs = zip(excerpts, scores).filter { $0.1 >= 0.3 }.sorted { $0.1 > $1.1 }.prefix(3).map { $0.0.id }
            }
            guard !bullet.refs.isEmpty, Set(bullet.refs).isSubset(of: allowed) else { return nil }
            return bullet
        }
    }
}
