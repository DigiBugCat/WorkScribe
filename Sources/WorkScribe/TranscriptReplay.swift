import Foundation
import AVFoundation
import CryptoKit
import WorkScribeCore

/// Read-only, opt-in replay of the actual disk queue → native connection → event reducer.
/// Results go to stdout; never instantiates AppModel or opens the user's meeting store.
enum TranscriptReplay {
    @MainActor static func batchWindow(path: String, start: Double, duration: Double) async throws {
        guard start.isFinite, duration.isFinite, start >= 0, duration > 0, duration <= 300 else {
            throw CaptureError.message("Batch window must be 0–300 seconds")
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1 else {
            throw CaptureError.message("Replay needs 16 kHz mono WAV")
        }
        file.framePosition = min(file.length, AVAudioFramePosition(start * 16000))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(duration * 16000))!
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let runtime = SpeechRuntime()
        do {
            try await runtime.start()
            let event = try await runtime.batch(samples)
            let words = TranscriptParser.timedWords(event: event, offset: start, fallbackStart: start)
            let result: [String: Any] = ["text": words.map(\.text).joined(separator: " "),
                "words": words.map { ["word": $0.text, "start": $0.start, "end": $0.end] as [String: Any] }]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
            await runtime.stop()
        } catch { await runtime.stop(); throw error }
    }
    @MainActor static func run(path: String, pace: Double) async throws {
        guard pace.isFinite && pace >= 0 else { throw CaptureError.message("Replay pace must be zero (burst) or a positive speed") }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1 else {
            throw CaptureError.message("Replay needs 16 kHz mono WAV")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ws-replay-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let backlog = try AudioBacklog(url: folder.appendingPathComponent("replay.pcm"))
        let runtime = SpeechRuntime()
        try await runtime.start()
        let connection = SpeechConnection(runtime: runtime)
        var events: [[String: Any]] = [], meeting = Meeting(title: "Replay")
        var reducer = LiveTranscript()
        connection.onEvent = { event in
            events.append(event)
            reducer.consume(event, source: "system", offset: 0, pressure: RecordingPressure(lag: backlog.pendingSeconds), meeting: &meeting)
        }
        try await connection.connect()
        let start = Date()
        var inputHash = SHA256(), outputHash = SHA256(), pushed = 0, consumed = 0, peakLag = 0.0
        let producer = Task { @MainActor in
            do {
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1600)!
                while file.framePosition < file.length {
                    try Task.checkCancellation()
                    try file.read(into: buffer)
                    var samples = (0..<Int(buffer.frameLength)).map { Int16(max(-32768, min(32767, Int((buffer.floatChannelData![0][$0] * 32768).rounded())))).littleEndian }
                    let data = samples.withUnsafeMutableBytes { Data($0) }
                    try backlog.append(data); inputHash.update(data: data); pushed += data.count
                    peakLag = max(peakLag, backlog.pendingSeconds)
                    if pace > 0 { try await Task.sleep(nanoseconds: UInt64(Double(buffer.frameLength) / 16000 / pace * 1e9)) }
                }
                backlog.finish()
            } catch { backlog.finish(throwing: error); throw error }
        }
        do {
            while let data = try await backlog.next() {
                try await connection.write(data)
                outputHash.update(data: data); consumed += data.count
                backlog.acknowledge(data.count)
                if ProcessInfo.processInfo.environment["WORKSCRIBE_REPLAY_PROGRESS"] != nil {
                    FileHandle.standardError.write(Data("Consumed \(Double(consumed) / 32000)s; backlog \(backlog.pendingSeconds)s\n".utf8))
                }
            }
            try await producer.value
            try await connection.finish()
            for source in reducer.unfinishedSources {
                reducer.consume(["type": "transcript.completed", "transcript": ""], source: source, offset: 0, pressure: .normal, meeting: &meeting)
            }
            connection.close(); await runtime.stop()
        } catch { producer.cancel(); connection.close(); await runtime.stop(); throw error }
        let finals = events.filter { ($0["type"] as? String)?.hasSuffix(".completed") == true }
        let value: [String: Any] = ["pace": pace, "elapsed_seconds": Date().timeIntervalSince(start),
            "input_bytes": pushed, "consumed_bytes": consumed, "audio_exactly_once": pushed == consumed && inputHash.finalize() == outputHash.finalize(),
            "peak_backlog_seconds": peakLag, "hidden_partials": reducer.hiddenPartials,
            "recognizer_text": finals.compactMap { $0["transcript"] as? String }.joined(separator: " "),
            "parsed_text": meeting.orderedSegments.map(\.text).joined(separator: " "),
            "event_text_disagreements": finals.filter { event in
                let a = (event["transcript"] as? String ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
                let b = (event["words"] as? [[String: Any]] ?? []).compactMap { $0["word"] as? String }
                return a != b
            }.count,
            "legacy_parsed_text": finals.map { event in
                let words = (event["words"] as? [[String: Any]] ?? []).filter { $0["start"] is Double && $0["end"] is Double }.compactMap { $0["word"] as? String }
                return words.isEmpty ? (event["transcript"] as? String ?? "") : words.joined(separator: " ")
            }.joined(separator: " "),
            "segments": try JSONSerialization.jsonObject(with: JSONEncoder().encode(meeting.segments)), "events": events]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]))
    }
}
