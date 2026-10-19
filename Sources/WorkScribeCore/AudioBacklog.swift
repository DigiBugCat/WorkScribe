import Foundation

/// Bounded, memory-only PCM queue. Capture never waits for inference. If inference
/// cannot keep up even after shedding optional work, fail explicitly rather than
/// silently lose speech or spill meeting audio to disk.
public final class AudioBacklog: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var pending = 0
    private var inFlight = 0
    private var closed = false
    private var failure: Error?
    private let capacity: Int
    public init(seconds: Int = 30) { capacity = max(1, seconds) * 32_000 }
    public struct Overflow: LocalizedError {
        public var errorDescription: String? { "Speech recognition could not keep up. Capture stopped; the transcript received so far is saved." }
    }
    public var pendingSeconds: Double { lock.withLock { Double(pending) / 32_000 } }
    public func append(_ data: Data) throws {
        try lock.withLock {
            guard !closed else { throw failure ?? CocoaError(.userCancelled) }
            guard data.count <= capacity - pending else { throw Overflow() }
            chunks.append(data); pending += data.count
        }
    }
    public func finish(throwing error: Error? = nil) {
        lock.withLock { closed = true; failure = error }
    }
    public func discard() {
        lock.withLock { chunks.removeAll(); pending = 0; inFlight = 0; closed = true }
    }
    public func acknowledge(_ count: Int) {
        lock.withLock {
            let acknowledged = min(max(0, count), inFlight)
            inFlight -= acknowledged; pending -= acknowledged
        }
    }
    public func next() async throws -> Data? {
        while true {
            try Task.checkCancellation()
            let result: (Data?, Bool) = try lock.withLock {
                if !chunks.isEmpty {
                    var data = chunks.removeFirst()
                    if data.count > 32_000 {
                        let remainder = Data(data.dropFirst(32_000))
                        data = Data(data.prefix(32_000)); chunks.insert(remainder, at: 0)
                    }
                    inFlight += data.count
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

/// The most recent 60 seconds delivered to ASR, for live single-speaker crops.
/// Timestamps are track-relative; no file or whole-meeting audio is retained.
public struct VoiceAudioWindow {
    private var bytes = Data()
    private var endFrame = 0
    private let capacity = 60 * 16_000
    public init() {}
    public mutating func append(_ data: Data) {
        bytes.append(data); endFrame += data.count / 2
        if bytes.count > capacity * 2 { bytes = Data(bytes.suffix(capacity * 2)) }
    }
    public func samples(start: Double, duration: Double) -> [Float]? {
        guard start.isFinite, duration.isFinite, start >= 0, duration >= 3, duration <= 10 else { return nil }
        let first = Int((start * 16_000).rounded()), count = Int((duration * 16_000).rounded())
        let origin = endFrame - bytes.count / 2
        guard first >= origin, first + count <= endFrame else { return nil }
        return bytes.withUnsafeBytes { raw in
            (first - origin ..< first - origin + count).map {
                Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32768
            }
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
