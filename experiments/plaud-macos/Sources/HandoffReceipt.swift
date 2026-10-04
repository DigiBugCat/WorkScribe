import Foundation
import CryptoKit

struct HandoffReceipt: Codable {
    let inventory: [Int: Int]
    let files: [URL: String]
    init(inventory: [Int: Int], paths: [URL]) throws {
        self.inventory = inventory
        self.files = try Dictionary(uniqueKeysWithValues: paths.map { ($0, try Self.digest($0)) })
    }
    func validate(inventory current: [Int: Int], recording: Bool) throws {
        guard !recording, current == inventory, current.isEmpty || !files.isEmpty else {
            throw PlaudAuthError.message("The recorder changed. Save its recordings again before releasing it.")
        }
        for (path, expected) in files {
            guard try Self.digest(path) == expected else {
                throw PlaudAuthError.message("A saved recording changed or is missing. Save again before releasing the device.")
            }
        }
    }
    private static func digest(_ path: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: path); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
