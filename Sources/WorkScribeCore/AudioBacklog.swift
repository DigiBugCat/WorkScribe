import Foundation
import Darwin

/// A single-consumer PCM queue. Audio lives on disk; only one bounded inference batch is in memory.
/// The capture writer never waits for the recognizer. Acknowledgement includes in-flight inference
/// in the lag measurement, so a blocked recognizer cannot make the queue look healthy.
public final class AudioBacklog: @unchecked Sendable {
    private let lock = NSLock()
    private let writer: FileHandle
    private let reader: FileHandle
    private var written: UInt64 = 0
    private var read: UInt64 = 0
    private var acknowledged: UInt64 = 0
    private var closed = false
    private var failure: Error?
    public let url: URL
    public init(url: URL) throws {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        writer = try FileHandle(forWritingTo: url)
        reader = try FileHandle(forReadingFrom: url)
    }
    deinit {
        try? writer.close(); try? reader.close()
        if closed && failure == nil && acknowledged == written { try? FileManager.default.removeItem(at: url) }
    }
    /// A process kill can leave AVAudioFile's WAV header unfinished. The PCM journal
    /// survives each write and can rebuild a playable file without trusting that header.
    public static func recoverWAV(journal: URL, destination: URL) throws {
        let size = try journal.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size % 2 == 0, size <= Int(UInt32.max) - 36 else { return }
        let temp = destination.appendingPathExtension(UUID().uuidString + ".recovering")
        defer { try? FileManager.default.removeItem(at: temp) }
        var header = Data()
        func word<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; withUnsafeBytes(of: &value) { header.append(contentsOf: $0) } }
        header.append(Data("RIFF".utf8)); word(UInt32(size + 36)); header.append(Data("WAVEfmt ".utf8))
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(16_000)); word(UInt32(32_000))
        word(UInt16(2)); word(UInt16(16)); header.append(Data("data".utf8)); word(UInt32(size))
        try header.write(to: temp)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        let output = try FileHandle(forWritingTo: temp), input = try FileHandle(forReadingFrom: journal)
        defer { try? output.close(); try? input.close() }
        try output.seekToEnd()
        while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty { try output.write(contentsOf: data) }
        try output.synchronize(); try output.close()
        guard rename(temp.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    public var pendingSeconds: Double { lock.withLock { Double(written - acknowledged) / 32_000 } }
    public func append(_ data: Data) throws {
        try lock.withLock {
            guard !closed else { throw CocoaError(.fileWriteUnknown) }
            try writer.write(contentsOf: data)
            written += UInt64(data.count)
        }
    }
    public func finish(throwing error: Error? = nil) {
        lock.withLock { closed = true; failure = error }
    }
    public func acknowledge(_ count: Int) { lock.withLock { acknowledged = min(read, acknowledged + UInt64(count)) } }
    public func next() async throws -> Data? {
        while true {
            try Task.checkCancellation()
            let result: (Data?, Bool) = try lock.withLock {
                if read < written {
                    let count = Int(min(32_000, written - read))
                    let data = try reader.read(upToCount: count) ?? Data()
                    guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                    read += UInt64(data.count)
                    return (data, false)
                }
                if let failure { throw failure }
                return (nil, closed)
            }
            if let data = result.0 { return data }
            if result.1 { return nil }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

public enum RecordingPressure: Int, Comparable {
    case normal, screenPaused, aiPaused, transcriptDelayed
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public init(lag: Double) {
        self = lag >= 12 ? .transcriptDelayed : lag >= 6 ? .aiPaused : lag >= 2 ? .screenPaused : .normal
    }
    public var message: String { "Your Mac is busy · still recording, the transcript will catch up" }
}
