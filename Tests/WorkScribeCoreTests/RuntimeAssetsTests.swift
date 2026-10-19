import Foundation
import XCTest
@testable import WorkScribeCore

final class RuntimeAssetsTests: XCTestCase {
    func testDatalessMetadataWinsOverLogicalSize() {
        XCTAssertEqual(RuntimeAssets.metadataState(exists: true, size: 5_700_000_000, flags: 0x40000000), .evicted)
        XCTAssertEqual(RuntimeAssets.metadataState(exists: false, size: 0, flags: 0), .missing)
        XCTAssertEqual(RuntimeAssets.metadataState(exists: true, size: 0, flags: 0), .wrongHash)
    }
    func testDeletedWeightIsRejectedEvenWhenMetadataSurvives() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("metadata".utf8).write(to: root.appendingPathComponent("metadata.json"))
        XCTAssertEqual(RuntimeAssets.inspect(root, manifest: ["weights.bin": "expected hash"]), .missing)
    }
    func testHashAndRecursiveBundleValidation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(RuntimeAssets.inspect(root), .missing)
        let file = root.appendingPathComponent("weights")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(RuntimeAssets.inspect(file, expected: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"), .present)
        XCTAssertEqual(RuntimeAssets.inspect(file, expected: "wrong"), .wrongHash)
        XCTAssertEqual(RuntimeAssets.inspect(root), .present)
        try Data().write(to: file)
        XCTAssertEqual(RuntimeAssets.inspect(root), .wrongHash)
        XCTAssertThrowsError(try RuntimeAssets.require(root))
    }
    func testE4BAndProjectorRejectUnpinnedBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["gemma-4-E4B-it-Q4_0.gguf", "mmproj-gemma-4-E4B-it-Q8_0.gguf"] {
            let file = root.appendingPathComponent(name)
            try Data("not model bytes".utf8).write(to: file)
            XCTAssertEqual(RuntimeAssets.inspect(file), .wrongHash)
        }
    }

}
