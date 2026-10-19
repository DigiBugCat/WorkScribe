import Foundation
import AVFoundation
import CryptoKit
import WorkScribeCore

/// Read-only, opt-in replay of the memory queue → native connection → event reducer.
/// Results go to stdout; never instantiates AppModel or opens the user's meeting store.
enum TranscriptReplay {
    @MainActor static func run(path: String, pace: Double) async throws {
        guard pace.isFinite && pace >= 0 else { throw CaptureError.message("Replay pace must be zero (burst) or a positive speed") }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1 else {
            throw CaptureError.message("Replay needs 16 kHz mono WAV")
        }
        let backlog = AudioBacklog()
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
                    while backlog.pendingSeconds >= 28 { try await Task.sleep(nanoseconds: 20_000_000) }
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

    /// Both tracks of one recording through the live recognizer and reducer, then the echo filter.
    /// Prints how many microphone segments repeated system speech, before and after filtering.
    @MainActor static func pair(system: String, microphone: String, offsets: [String: Double]) async throws {
        let runtime = SpeechRuntime()
        try await runtime.start()
        var meeting = Meeting(title: "Replay")
        do {
            for (source, path) in [("system", system), ("microphone", microphone)] {
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
                guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1 else {
                    throw CaptureError.message("Replay needs 16 kHz mono WAV")
                }
                var reducer = LiveTranscript()
                let connection = SpeechConnection(runtime: runtime)
                connection.onEvent = { event in
                    reducer.consume(event, source: source, offset: offsets[source] ?? 0, pressure: .normal, meeting: &meeting)
                }
                try await connection.connect()
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16000)!
                while file.framePosition < file.length {
                    try file.read(into: buffer)
                    var samples = (0..<Int(buffer.frameLength)).map { Int16(max(-32768, min(32767, Int((buffer.floatChannelData![0][$0] * 32768).rounded())))).littleEndian }
                    try await connection.write(samples.withUnsafeMutableBytes { Data($0) })
                }
                try await connection.finish()
                for unfinished in reducer.unfinishedSources {
                    reducer.consume(["type": "transcript.completed", "transcript": ""], source: unfinished, offset: offsets[source] ?? 0, pressure: .normal, meeting: &meeting)
                }
                connection.close()
            }
            await runtime.stop()
        } catch { await runtime.stop(); throw error }
        let before = meeting.segments.filter { $0.source == "microphone" }
        let matches = EchoFilter.matches(meeting.segments)
        meeting.removeEchoes()
        func rows(_ segments: [Segment]) -> [[String: Any]] {
            segments.sorted { $0.start < $1.start }.map { ["source": $0.source, "start": ($0.start * 10).rounded() / 10, "text": $0.text] }
        }
        let value: [String: Any] = [
            "system_segments": meeting.segments.filter { $0.source == "system" }.count,
            "microphone_segments_before": before.count,
            "echo_duplicates_before": matches.count,
            "microphone_segments_after": meeting.segments.filter { $0.source == "microphone" }.count,
            "echo_duplicates_after": EchoFilter.matches(meeting.segments).count,
            "kept_microphone": rows(meeting.segments.filter { $0.source == "microphone" }),
            "removed_echo": rows(meeting.echoSegments ?? []),
            "system": rows(meeting.segments.filter { $0.source == "system" })]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]))
    }
}
