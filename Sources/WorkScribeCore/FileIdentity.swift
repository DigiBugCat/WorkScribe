import Foundation
import Darwin

public enum FileIdentity {
    /// Resolve the existing ancestor too, so a not-yet-written note has the same identity
    /// before and after creation. Never standardize again after realpath (macOS aliases).
    public static func url(_ value: URL) -> URL {
        var ancestor = value
        var tail: [String] = []
        while true {
            if let resolved = realpath(ancestor.path, nil) {
                defer { free(resolved) }
                return tail.reversed().reduce(URL(fileURLWithPath: String(cString: resolved))) { $0.appendingPathComponent($1) }
            }
            guard ancestor.path != "/" else { return value.standardizedFileURL }
            tail.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
    }
    public static func path(_ value: String) -> String { url(URL(fileURLWithPath: value)).path }
}
