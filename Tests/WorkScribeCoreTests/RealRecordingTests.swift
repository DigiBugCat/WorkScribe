import XCTest
@testable import WorkScribeCore

final class RealRecordingTests: XCTestCase {
    func testReadableTurnsPreserveEvidenceAndImproveExcerpts() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "realrun-fragments", withExtension: "json", subdirectory: "Golden"))
        var meeting = Meeting(title: "Synthetic two-minute live stream")
        meeting.segments = try JSONDecoder().decode([Segment].self, from: Data(contentsOf: url))
        let turns = TranscriptTurns.group(meeting)
        let before = meeting.segments.map { $0.text.split(separator: " ").count }.sorted()
        let after = turns.map { $0.text.split(separator: " ").count }.sorted()
        XCTAssertEqual(before.count, 25); XCTAssertEqual(before[12], 3)
        XCTAssertEqual(after.count, 5); XCTAssertEqual(after[2], 15)
        XCTAssertEqual(turns.flatMap(\.segments).map(\.id), meeting.orderedSegments.map(\.id))
        XCTAssertEqual(turns.map(\.text).joined(separator: " "), meeting.orderedSegments.map(\.text).joined(separator: " "))
        let chunks = Chunker.transcript(meeting)
        XCTAssertEqual(chunks.count, 25)
        XCTAssertEqual(chunks.map(\.segmentID), meeting.orderedSegments.map(\.id))
        XCTAssertEqual(chunks.map(\.text), meeting.orderedSegments.map(\.text))
        // Citations already attached to one of the original fragments remain resolvable.
        let legacy = Chunker.transcript(meeting)
        XCTAssertTrue(legacy.allSatisfy { APIShapes.chunkMap(meeting)[$0.id] != nil })
        print("realrun fixture: \(meeting.segments.count) finalized segments -> \(chunks.count) passage chunks; all original IDs and times retained")
    }

    func testTurnsRespectPausesSourcesSpeakerOverridesAndUnknownVoices() {
        var meeting = Meeting(title: "Boundaries")
        let a = Segment(source: "system", speaker: "system:speaker-1", start: 0, end: 1, text: "hello")
        var b = a; b.id = "b"; b.start = 1.2; b.end = 2; b.text = "again"
        meeting.segments = [a,b]
        XCTAssertEqual(TranscriptTurns.group(meeting).count, 1)
        meeting.segmentAssignments = [b.id: .init(name: "Another person")]
        XCTAssertEqual(TranscriptTurns.group(meeting).count, 2)
        meeting.segmentAssignments = nil
        b.start = 4; b.end = 5; meeting.segments = [a,b]
        XCTAssertEqual(TranscriptTurns.group(meeting).count, 2)
        b.start = 1.2; b.source = "microphone"; meeting.segments = [a,b]
        XCTAssertEqual(TranscriptTurns.group(meeting).count, 2)
        b.source = "system"; b.speaker = "system:unknown"; var c = b; c.id = "c"; c.start = 2; c.end = 3
        meeting.segments = [b,c]
        XCTAssertEqual(TranscriptTurns.group(meeting).count, 2)
    }

    func testVaultAndDocumentIdentityThroughArbitrarySymlinks() throws {
        let root = try temporaryFolder("path-identity")
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("unrelated-name")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let state = root.appendingPathComponent("state")
        let viaAlias = VaultStore(root: alias, stateDirectory: state)
        let viaActual = VaultStore(root: actual, stateDirectory: state)
        XCTAssertEqual(viaAlias.root, viaActual.root)
        XCTAssertEqual(viaAlias.stateURL, viaActual.stateURL)
        let meeting = Meeting(title: "Same folder")
        let document = try viaAlias.openDocument(meeting)
        XCTAssertEqual(document.path, FileIdentity.path(document.path))
        XCTAssertEqual(try viaActual.openDocument(meeting).path, document.path)
        try viaActual.validateDocumentPath(document, meetingID: meeting.id)
        XCTAssertEqual(FileIdentity.path(alias.appendingPathComponent("not-created/note.md").path), actual.appendingPathComponent("not-created/note.md").path)
    }
}
