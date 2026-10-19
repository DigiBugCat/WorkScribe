import XCTest

/// The owner's rule: WorkScribe has no cloud capabilities. Inference, answers, notes and titles run
/// on this Mac; HTTP clients are limited to the verification API and an explicitly selected,
/// loopback-only experimental benchmark backend.
final class NoCloudTests: XCTestCase {
    private func sources() throws -> [(String, String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        return try files.map { ($0.path.replacingOccurrences(of: root.path + "/", with: ""), try String(contentsOf: $0, encoding: .utf8)) }
    }

    func testNoCloudProviderKeyStorageOrNetworkClient() throws {
        let all = try sources()
        XCTAssertGreaterThan(all.count, 50)
        for (path, text) in all {
            let lower = text.lowercased()
            for banned in ["openai", "api.openai.com", "gpt-", "usecloudmodels", "cloudsettings", "api key", "apikey", "sk-…", "responses api"] {
                XCTAssertFalse(lower.contains(banned), "\(path) mentions \(banned)")
            }
            // Keychain is only the Plaud device session (optional build) and a screen-privacy bundle ID.
            if lower.contains("keychain") {
                XCTAssertTrue(path.contains("Plaud") || path.hasSuffix("Screen.swift"), "\(path) uses the Keychain")
            }
            if text.contains("URLSession") {
                let allowed = ["Sources/WorkScribe/APIVerification.swift", "Sources/WorkScribe/DoryEvaluation.swift"]
                XCTAssertTrue(allowed.contains(path), "\(path) opens a network client")
                XCTAssertTrue(text.contains("127.0.0.1"), "verification and benchmark clients must stay on loopback")
                if path.hasSuffix("DoryEvaluation.swift") {
                    XCTAssertTrue(text.contains("endpoint.scheme == \"http\""))
                    XCTAssertTrue(text.contains("[\"127.0.0.1\", \"[::1]\", \"::1\"].contains(endpoint.host"))
                    XCTAssertTrue(text.contains("completionHandler(nil)"), "the benchmark must reject redirects")
                }
            }
        }
    }
}
