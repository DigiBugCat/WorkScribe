import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import WorkScribeCore
@testable import WorkScribe

final class NoteImageUnderstandingTests: XCTestCase {
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
