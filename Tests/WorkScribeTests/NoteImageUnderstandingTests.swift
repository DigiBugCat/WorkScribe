import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import WorkScribeCore
@testable import WorkScribe

final class NoteImageUnderstandingTests: XCTestCase {
    private actor ImageTextModel: TextModel {
        nonisolated let displayName = "Fixture E4B"
        nonisolated let backend = TextBackend.llama
        nonisolated let isAvailable = true
        var instruction = ""
        func generate(_ request: TextRequest) async throws -> TextGeneration {
            instruction = request.instruction
            return TextGeneration(text: "* **Chart:** Revenue increased to forty dollars.", stats: TextStats())
        }
        nonisolated func stream(_ request: TextRequest) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
        func prewarm(_ request: TextRequest?) async {}
        func release() async {}
    }
    func testImageObservationReachesResidentTextModel() async throws {
        var image = NoteImage(target: "chart.png", path: "chart.png")
        image.text = "Revenue $40"; image.caption = "A revenue chart."
        var note = Note(text: "![[chart.png]]", createdAt: nil); note.images = [image]
        var meeting = Meeting(title: "Chart"); meeting.notes = [note]
        let model = ImageTextModel()
        let draft = try await Enrich(textModel: model, decisionModel: FixtureDecision(), embeddingSource: { FixtureEmbedder() }).enhance(meeting, incremental: true)
        let instruction = await model.instruction
        XCTAssertTrue(instruction.contains("<image>"))
        XCTAssertTrue(instruction.contains("Revenue $40"))
        XCTAssertEqual(draft?.model, "Fixture E4B")
    }
    func testOldCaptionCannotSurviveAChangedOrMissingImage() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let url=root.appendingPathComponent("image.png")
        let context=try XCTUnwrap(CGContext(data:nil,width:8,height:8,bitsPerComponent:8,bytesPerRow:32,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:8,height:8))
        let image=try XCTUnwrap(context.makeImage())
        let destination=try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
        var reference=NoteImage(target:"image.png",path:url.path)
        reference.text="old OCR";reference.caption="old caption";reference.fingerprint="old hash"
        let analyzer=NoteImageUnderstanding()
        let fresh=await analyzer.read(reference,note:root.appendingPathComponent("note.md"),vault:root)
        XCTAssertNil(fresh.caption);XCTAssertNotEqual(fresh.text,"old OCR");XCTAssertNotEqual(fresh.fingerprint,"old hash")
        try FileManager.default.removeItem(at:url)
        let missing=await analyzer.read(reference,note:root.appendingPathComponent("note.md"),vault:root)
        XCTAssertNil(missing.caption);XCTAssertNil(missing.text);XCTAssertEqual(missing.method,"unavailable")
    }
}
