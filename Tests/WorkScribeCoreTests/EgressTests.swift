import XCTest

/// What may leave this Mac, as a rule on the source.
///
/// Speech recognition, speaker labels, search and screen reading run here. Generated text (note
/// lines, titles, briefs, answers, image captions) is written by Codex, and the one way to it is the
/// `codex app-server` child process started in `CodexAppServer.swift`. The app itself opens no
/// network client, holds no API key, and talks to no model endpoint directly.
final class EgressTests: XCTestCase {
    private func sources() throws -> [(String, String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        return try files.map { ($0.path.replacingOccurrences(of: root.path + "/", with: ""), try String(contentsOf: $0, encoding: .utf8)) }
    }

    func testNoNetworkClientNoKeysAndOneWayToCodex() throws {
        let all = try sources()
        XCTAssertGreaterThan(all.count, 50)
        var launchers: [String] = []
        for (path, text) in all {
            let lower = text.lowercased()
            // No model endpoint, key or key setting anywhere: the app never calls a provider itself.
            for banned in ["api.openai.com", "chatgpt.com", "/v1/responses", "usecloudmodels", "cloudsettings", "api key", "apikey", "sk-…", "responses api"] {
                XCTAssertFalse(lower.contains(banned), "\(path) mentions \(banned)")
            }
            // Keychain is only the Plaud device session (optional build) and a screen-privacy bundle ID.
            if lower.contains("keychain") {
                XCTAssertTrue(path.contains("Plaud") || path.hasSuffix("Screen.swift"), "\(path) uses the Keychain")
            }
            // The local API's own smoke test is the only network client, and it stays on loopback.
            if text.contains("URLSession") || text.contains("NWConnection(") || text.contains("URLRequest(") {
                XCTAssertEqual(path, "Sources/WorkScribe/APIVerification.swift", "\(path) opens a network client")
                XCTAssertTrue(text.contains("127.0.0.1"), "the verification client must stay on loopback")
            }
            if text.contains("\"app-server\"") { launchers.append(path) }
        }
        XCTAssertEqual(launchers, ["Sources/WorkScribe/CodexAppServer.swift"], "Codex is started from exactly one place")
    }

    /// Codex's credentials file is only ever linked or unlinked, never opened: the app has no use for a token.
    func testTheAppNeverReadsCodexCredentials() throws {
        for (path, text) in try sources() where text.contains("auth.json") {
            XCTAssertTrue(["Sources/WorkScribe/CodexAppServer.swift", "Sources/WorkScribe/CodexVerification.swift"].contains(path),
                          "\(path) touches Codex's credentials")
            for reader in ["Data(contentsOf: credentials", "String(contentsOf: credentials", "contents(atPath: credentials"] {
                XCTAssertFalse(text.contains(reader), "\(path) reads Codex's credentials")
            }
        }
        // The verification scan is the one place the Codex home's files are read, and it skips that file.
        let verification = try XCTUnwrap(try sources().first { $0.0.hasSuffix("CodexVerification.swift") }).1
        XCTAssertTrue(verification.contains("url.lastPathComponent != \"auth.json\""))
    }
}
