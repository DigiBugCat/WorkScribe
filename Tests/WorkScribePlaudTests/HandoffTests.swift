import XCTest
@testable import WorkScribePlaud

final class HandoffTests: XCTestCase {
    func testReleaseRejectsNewRecordingChangedBackupAndMissingBackup() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("recording.wav")
        try Data("verified recording".utf8).write(to: file)
        let receipt = try HandoffReceipt(inventory: [42: 1024], paths: [file])
        XCTAssertNoThrow(try receipt.validate(inventory: [42: 1024], recording: false))
        XCTAssertThrowsError(try receipt.validate(inventory: [42: 1024, 43: 512], recording: false))
        XCTAssertThrowsError(try receipt.validate(inventory: [42: 2048], recording: false))
        XCTAssertThrowsError(try receipt.validate(inventory: [42: 1024], recording: true))
        try Data("changed recording".utf8).write(to: file)
        XCTAssertThrowsError(try receipt.validate(inventory: [42: 1024], recording: false))
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try receipt.validate(inventory: [42: 1024], recording: false))
    }
    func testEmptyRecorderIsAllowedButMissingBackupsAreNot() throws {
        let empty = try HandoffReceipt(inventory: [:], paths: [])
        XCTAssertNoThrow(try empty.validate(inventory: [:], recording: false))
        let incomplete = try HandoffReceipt(inventory: [42: 1024], paths: [])
        XCTAssertThrowsError(try incomplete.validate(inventory: [42: 1024], recording: false))
    }
}

final class PlaudIdentityTests: XCTestCase {
    func testSignInReusesTheLabUserSoTheRecorderKeepsItsOwner() throws {
        let suite = "workscribe-identity-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("workscribe-existing-lab-user", forKey: PlaudIdentity.key)
        XCTAssertEqual(PlaudIdentity(defaults: defaults).userID(), "workscribe-existing-lab-user")
    }
    func testFirstSignInCreatesOneStableUser() throws {
        let suite = "workscribe-identity-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = PlaudIdentity(defaults: defaults).userID()
        XCTAssertTrue(first.hasPrefix("workscribe-"))
        XCTAssertEqual(PlaudIdentity(defaults: defaults).userID(), first)
    }
    func testSessionIDsBecomeDatesOnlyWhenPlausible() {
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        XCTAssertEqual(PlaudSavedRecording.recordedAt(sessionID: 1_790_000_000, now: now), Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertNil(PlaudSavedRecording.recordedAt(sessionID: 42, now: now))
        XCTAssertNil(PlaudSavedRecording.recordedAt(sessionID: 1_891_000_000, now: now))
    }
}
