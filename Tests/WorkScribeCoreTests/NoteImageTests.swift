import XCTest
@testable import WorkScribeCore

final class NoteImageTests: XCTestCase {
    func testBlocksAndDataBoundary() throws {
        for text in ["![[a.png]]", "- ![[a.png|400]]", "1. ![x](<my image.png>)", "- [ ] ![x](a.png)"] {
            let parts = NoteImageContent.parse(text)
            XCTAssertEqual(parts.shorthand, ""); XCTAssertEqual(parts.targets.count, 1)
        }
        XCTAssertEqual(NoteImageContent.parse("a thought ![[a.png]]").shorthand, "a thought")
        XCTAssertTrue(NoteImageContent.parse("`![[a.png]]`").targets.isEmpty)
        XCTAssertEqual(NoteImageContent.parse("![x](https://x/a.png)").shorthand, "")
        XCTAssertEqual(NoteImageContent.parse("![figure][ref]", source: "[ref]: a.png").targets,["a.png"])
        let source = "![[a.png]]"
        let d = NoteDocument(path:"/tmp/n.md",source:source,blocks:[.init(id:"a",from:0,to:source.utf16.count,text:source,at:12)])
        var n = d.notes(previous:[])[0]
        XCTAssertTrue(n.isImage); XCTAssertTrue(n.matchingText.isEmpty)
        var m = Meeting(title:"test"); m.notes=[n]
        XCTAssertTrue(try SelectionFixture.plan(m,incremental:true).isEmpty)
        n.images?[0].text="Main thread stall 2900 ms"; m.notes=[n]
        let plan=try SelectionFixture.plan(m,incremental:true)
        let prompt=LinePrompt.build(plan.targets[0], excerpts: plan.evidence(for: plan.targets[0]))
        XCTAssertTrue(prompt.contains("Main thread stall 2900 ms"))
        XCTAssertFalse(prompt.contains("![[a.png]]"))
        n.line.apply(.line(Bullet(topic: "Launch", text: "Main thread stall is 2900 ms.", refs: []), []), basis: "image", query: n.text, at: .distantPast)
        XCTAssertEqual(n.text,source)
        XCTAssertTrue(n.line.text?.contains("2900 ms") == true)
        m.notes=[n]
        XCTAssertTrue(try d.finalizedText(meeting:m).contains("![[a.png]]\n*Main thread stall is 2900 ms.*"))
    }
    func testVaultBoundaryAndGrabPayload() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let vault=root.appendingPathComponent("Vault"), outside=root.appendingPathComponent("secret.png")
        try FileManager.default.createDirectory(at:vault,withIntermediateDirectories:true)
        try Data([1]).write(to:outside)
        let file=vault.appendingPathComponent("a.png"); try Data([1]).write(to:file)
        let note=vault.appendingPathComponent("n.md")
        XCTAssertNotNil(NoteImageContent.resolve(.init(target:"a.png"),note:note,vault:vault))
        XCTAssertNil(NoteImageContent.resolve(.init(target:"a.png",path:outside.path),note:note,vault:vault))
        let link=vault.appendingPathComponent("link.png");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:outside)
        XCTAssertNil(NoteImageContent.resolve(.init(target:"link.png"),note:note,vault:vault))
        let grab=GrabMoment(data:Data([1,2,3]),at:12)
        XCTAssertEqual(Data(base64Encoded:grab.png),Data([1,2,3]));XCTAssertTrue(grab.filename.hasSuffix(".png"))
        XCTAssertEqual(try APIRoute.match(method:"POST",path:"/v1/meetings/x/grab-moment").get(),.grabMoment("x"))
    }
}

private struct ImageTestEmbedder: Embedder {
    let modelID = "image-test/2", dimension = 2, supportsAudio = false, supportsImages = true
    func text(_ value: String, role: TextRole) async throws -> [Float] { [1,0] }
    func audio(_ pcm16k: [Float]) async throws -> [Float] { throw EmbedderError.audioUnsupported }
    func image(_ url: URL) async throws -> [Float] { [0,1] }
}
private struct ImageTestExtractor: FileExtracting {
    func passages(of url: URL, kind: ChunkKind) async throws -> (title: String?, passages: [Passage]) { (nil,[Passage(text:"persistent plot")]) }
    func audioWindows(of url: URL, _ body: (AudioWindow) async throws -> Void) async throws {}
}
extension NoteImageTests {
    func testVaultImageVectorsSurviveMeetingPurgeAndLeaveWithFile() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let vault=root.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at:vault,withIntermediateDirectories:true)
        let image=FileIdentity.url(vault.appendingPathComponent("user-image.png"));let original=Data([1,2,3]);try original.write(to:image)
        let index=try SearchIndex(url:root.appendingPathComponent("index.sqlite"))
        let indexer=VaultIndexer(index:index,embedder:ImageTestEmbedder(),extractor:ImageTestExtractor())
        _ = try await indexer.sync(vault:vault)
        XCTAssertEqual(try index.vectorStats().count,2)
        let store=MeetingStore(root:root.appendingPathComponent("Meetings"))
        var meeting=Meeting(title:"Ephemeral");meeting.endedAt=Date();meeting.retention="finalized"
        var n=Note(text:"![[user-image.png]]",createdAt:3)
        var derived=NoteImage(target:"user-image.png",path:image.path);derived.text="secret OCR";derived.caption="secret caption";n.images=[derived]
        meeting.notes=[n];try store.save(meeting)
        let journal=RetentionStore(meetings:store);try journal.save(RetentionReceipt(meeting,vaultPath:vault.appendingPathComponent("note.md").path))
        try journal.purge(meeting.id,meetings:store,conversations:ConversationStore(root:root.appendingPathComponent("Chats")),index:index)
        XCTAssertTrue((try store.load(meeting.id).notes ?? []).isEmpty)
        XCTAssertEqual(try Data(contentsOf:image),original)
        let sources = try index.sources(kind:.vault).map(\.ref)
        XCTAssertNotNil(try index.source(ref:image.path), "Expected \(image.path), got \(sources)");XCTAssertEqual(try index.vectorStats().count,2)
        try FileManager.default.removeItem(at:image)
        _ = try await indexer.update(paths:[image.path],vault:vault)
        XCTAssertNil(try index.source(ref:image.path));XCTAssertEqual(try index.vectorStats().count,0)
    }
}

extension NoteImageTests {
    func testImageEditAndDeletionRefreshReferencingNote() async throws {
        let root=try temporaryFolder("image-dependencies")
        defer { try? FileManager.default.removeItem(at:root) }
        let image=root.appendingPathComponent("plot.png"), note=root.appendingPathComponent("Tuesday.md")
        try Data([1]).write(to:image);try "# Tuesday review\n![[plot.png]]".write(to:note,atomically:true,encoding:.utf8)
        let index=try SearchIndex(url:try temporaryFolder("image-index").appendingPathComponent("index.sqlite"))
        let indexer=VaultIndexer(index:index,embedder:ImageTestEmbedder(),extractor:ImageTestExtractor())
        _ = try await indexer.sync(vault:root)
        XCTAssertTrue(try index.search(SearchRequest("persistent plot")).hits.contains { $0.ref == note.path && $0.kind == .image })
        try FileManager.default.removeItem(at:image)
        _ = try await indexer.update(paths:[image.path],vault:root)
        XCTAssertFalse(try index.search(SearchRequest("persistent plot")).hits.contains { $0.kind == .image })
        XCTAssertNotNil(try index.source(ref:note.path))
    }
}
