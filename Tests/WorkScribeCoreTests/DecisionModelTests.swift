import XCTest
@testable import WorkScribeCore

final class DecisionModelTests: XCTestCase {
    struct Gate: DecisionModel {
        var relevanceThreshold = 0.1
        var answerabilityThreshold = 0.5
        var values: [Double]
        func relevance(jot: Note, candidates: [TranscriptChunk]) throws -> [Double] { values }
        func answerability(jot: Note, evidence: [TranscriptChunk]) throws -> Double { 0 }
    }
    func testPythonExportedHeadMatchesNativeInference() throws {
        struct Fixture: Decodable {
            struct Example: Decodable { var task: String; var features: [Double]; var expected: Double }
            var artifact: EmbeddingDecisionModel.Artifact
            var examples: [Example]
        }
        for name in ["decision-head-parity", "decision-context-parity"] {
            // The Python-exported golden files were lost with /private/tmp on 2026-10-18 and need the
            // training data to regenerate; until then this parity check has nothing to compare against.
            guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Golden") else {
                throw XCTSkip("\(name).json golden is missing; regenerate it with scripts/train-decision-head.py")
            }
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
            for example in fixture.examples {
                let head = try XCTUnwrap(fixture.artifact.heads[example.task])
                XCTAssertEqual(try head.probability(example.features), example.expected, accuracy: 1e-12)
            }
        }
    }


    func testCheapFeatureDefinitionAndStableTemperature() throws {
        let note = Note(text: "price seat?", createdAt: 620)
        let c = TranscriptChunk(id: "s", segmentID: "s", speaker: "A", start: 10, end: 20, text: "The price is ten per seat")
        let f = EmbeddingDecisionModel.features(jot: note, chunk: c, cosine: 0.7, speakerChanged: true)
        XCTAssertEqual(f[0], 0.7); XCTAssertEqual(f[1], 1); XCTAssertEqual(f[2], 1)
        XCTAssertEqual(f[3], 1); XCTAssertEqual(f[4], 0.5)
        let head = EmbeddingDecisionModel.Head(feature_kind: "cheap", mean: [0], scale: [1], weights: [2], bias: 0, temperature: 2)
        XCTAssertEqual(try head.probability([1]), 1 / (1 + exp(-1)), accuracy: 1e-12)
        XCTAssertEqual(try head.probability([-1000]), 0)
        XCTAssertThrowsError(try head.probability([.nan]))
    }
}
