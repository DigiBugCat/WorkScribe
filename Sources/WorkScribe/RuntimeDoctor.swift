import Foundation
import WorkScribeCore

/// The same repair command powers bootstrap, CLI and the background launch check.
enum RuntimeDoctor {
    static var script: URL {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/runtime/scripts/runtime-doctor.py")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/runtime-doctor.py")
    }
    static func run(checkOnly: Bool = false, progress: @escaping @Sendable (String) -> Void = { _ in }) throws -> Int32 {
        let process = Process(), pipe = Pipe()
        let environment = ProcessInfo.processInfo.environment
        let savedPython = try? String(contentsOf: RuntimeAssets.home.appendingPathComponent(".python-path"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pathCandidates = (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/python3" }
        let candidates = [environment["WORKSCRIBE_PYTHON"], savedPython].compactMap { $0 }
            + pathCandidates + ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        let python = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        process.executableURL = URL(fileURLWithPath: python ?? "/usr/bin/env")
        process.arguments = (python == nil ? ["python3"] : []) + [script.path] + (checkOnly ? ["--check"] : [])
        var childEnvironment = environment
        childEnvironment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = childEnvironment
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        var pending = Data()
        while true {
            let data = pipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            pending.append(data)
            while let newline = pending.firstIndex(of: 10) {
                progress(String(decoding: pending[..<newline], as: UTF8.self))
                pending.removeSubrange(...newline)
            }
        }
        if !pending.isEmpty { progress(String(decoding: pending, as: UTF8.self)) }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
