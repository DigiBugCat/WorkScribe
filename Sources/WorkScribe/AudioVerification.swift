import Foundation
@preconcurrency import AVFoundation
import WorkScribeCore

/// Exercises the shipped native bridge with a fixture, without opening the
/// microphone or writing synthetic meetings into the user's library.
enum AudioVerification {
    @MainActor static func run(path: String) async throws {
        let runtime = SpeechRuntime()
        try await runtime.start()
        do {
            let result = try await collect(path: path, runtime: runtime)
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
        }
        catch { await runtime.stop(); throw error }
        await runtime.stop()
    }
    @MainActor static func verifyWarm(path: String) async throws {
        let runtime = SpeechRuntime()
        do {
            let cold = Date()
            async let firstWarm: Void = runtime.warmUp()
            async let concurrentWarm: Void = runtime.warmUp()
            _ = try await (firstWarm, concurrentWarm)
            let warmupSeconds = Date().timeIntervalSince(cold)
            let ready = Date(); try await runtime.warmUp()
            let readyCheck = Date().timeIntervalSince(ready)
            let first = try await collect(path: path, runtime: runtime)
            await runtime.closeStreams()
            let second = try await collect(path: path, runtime: runtime)
            await runtime.closeStreams()
            let diagnostics = try await runtime.diagnostics()
            guard diagnostics.loaded, diagnostics.warmed, diagnostics.loadCount == 1, diagnostics.streamCount == 0 else {
                throw CaptureError.message("Warm engine was not retained between sessions")
            }
            func transcript(_ result: [String: Any]) -> String {
                (result["events"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "transcript.completed" }
                    .compactMap { $0["transcript"] as? String }.joined(separator: " ")
            }
            guard transcript(first) == transcript(second) else { throw CaptureError.message("Recording state leaked between sessions") }
            let result: [String: Any] = ["warmup_seconds": warmupSeconds, "ready_check_ms": readyCheck * 1000,
                "first_stream_open_ms": (first["open_seconds"] as! Double) * 1000,
                "second_stream_open_ms": (second["open_seconds"] as! Double) * 1000,
                "model_load_count": diagnostics.loadCount, "fresh_session_transcripts_match": true]
            await runtime.stop()
            guard try await !runtime.diagnostics().loaded else { throw CaptureError.message("Shutdown retained the model") }
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
        } catch { await runtime.stop(); throw error }
    }
    @MainActor private static func collect(path: String, runtime: SpeechRuntime) async throws -> [String: Any] {
        let connection = SpeechConnection(runtime: runtime)
        var events: [[String: Any]] = []
        connection.onEvent = { events.append($0) }
        let opening = Date()
        try await connection.connect()
        let openSeconds = Date().timeIntervalSince(opening)
        defer { connection.close() }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: outputFormat) else {
            throw CaptureError.message("Cannot convert verification audio")
        }
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        let start = Date()
        while file.framePosition < file.length {
            try file.read(into: input)
            let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / input.format.sampleRate)) + 256
            let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)!
            var used = false, error: NSError?
            converter.convert(to: output, error: &error) { _, state in
                if used { state.pointee = .noDataNow; return nil }
                used = true; state.pointee = .haveData; return input
            }
            if let error { throw error }
            let bytes = Data(bytes: output.int16ChannelData![0], count: Int(output.frameLength) * 2)
            try await connection.write(bytes)
        }
        try await connection.finish()
        let finals = events.filter { ($0["type"] as? String)?.hasSuffix(".completed") == true }
        guard finals.contains(where: { !($0["transcript"] as? String ?? "").isEmpty }) else {
            throw CaptureError.message("No final transcript produced")
        }
        return ["elapsed_seconds": Date().timeIntervalSince(start), "open_seconds": openSeconds, "events": events]
    }
}
