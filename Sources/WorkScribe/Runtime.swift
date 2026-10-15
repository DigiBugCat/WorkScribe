import Foundation
import CNemo
import WorkScribeCore

/// All model and stream calls stay inside WorkScribe on one inference queue.
final class SpeechRuntime: @unchecked Sendable {
    private let queue = DispatchQueue(label: "WorkScribe.inference", qos: .userInitiated)
    private var recognizer: OpaquePointer?
    private var streams: [UUID: OpaquePointer] = [:]
    private var warmed = false
    private var loadCount = 0
    func start() async throws {
        try await perform {
            if self.recognizer != nil { return }
            let asr = RuntimeAssets.model("nemotron-3.5-asr-streaming-0.6b.q8_0.gguf")
            let diar = RuntimeAssets.model("Nemotron-3-Diarization.q8_0.gguf")
            try RuntimeAssets.require(asr)
            try RuntimeAssets.require(diar)
            try self.check(ws_engine_create(asr.path, diar.path, &self.recognizer))
            self.loadCount += 1
        }
    }
    /// Prime inference as well as loading weights. The scratch stream is never
    /// exposed to recording state, so its text, timestamps and speakers vanish.
    func warmUp() async throws {
        try await start()
        try await perform {
            guard !self.warmed, let recognizer = self.recognizer else { return }
            var scratch: OpaquePointer?
            try self.check(ws_stream_create(recognizer, &scratch))
            guard let scratch else { throw CaptureError.message("Cannot warm the speech engine") }
            defer { nemo_speech_asr_stream_close(scratch) }
            let silence = [Float](repeating: 0, count: 32000)
            try self.check(nemo_speech_asr_stream_push_f32(scratch, silence, silence.count, 16000))
            _ = try self.drain(scratch)
            try self.check(nemo_speech_asr_stream_finish(scratch))
            _ = try self.drain(scratch)
            self.warmed = true
        }
    }
    func closeStreams() async {
        await withCheckedContinuation { continuation in
            queue.async {
                for stream in self.streams.values { nemo_speech_asr_stream_close(stream) }
                self.streams = [:]
                continuation.resume()
            }
        }
    }
    struct Diagnostics: Codable { let loaded: Bool; let warmed: Bool; let loadCount: Int; let streamCount: Int }
    func diagnostics() async throws -> Diagnostics {
        try await perform { Diagnostics(loaded: self.recognizer != nil, warmed: self.warmed, loadCount: self.loadCount, streamCount: self.streams.count) }
    }
    func stop() async {
        await withCheckedContinuation { continuation in
          queue.async {
            for stream in self.streams.values { nemo_speech_asr_stream_close(stream) }
            self.streams = [:]
            if let recognizer = self.recognizer { nemo_speech_asr_destroy(recognizer) }
            self.recognizer = nil
            self.warmed = false
            continuation.resume()
          }
        }
    }
    func open(_ id: UUID) async throws {
        try await perform {
            guard let recognizer = self.recognizer else { throw CaptureError.message("Speech model is not loaded") }
            var stream: OpaquePointer?
            try self.check(ws_stream_create(recognizer, &stream)); self.streams[id] = stream
        }
    }
    func push(_ data: Data, id: UUID) async throws -> [[String: Any]] {
        try await perform {
            guard let stream = self.streams[id] else { throw CaptureError.message("Speech stream is closed") }
            let samples: [Float] = data.withUnsafeBytes { raw in
                (0..<(data.count / 2)).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32768 }
            }
            try self.check(nemo_speech_asr_stream_push_f32(stream, samples, samples.count, 16000))
            return try self.drain(stream)
        }
    }
    func finish(_ id: UUID) async throws -> [[String: Any]] {
        try await perform {
            guard let stream = self.streams[id] else { throw CaptureError.message("Speech stream is closed") }
            try self.check(nemo_speech_asr_stream_finish(stream)); return try self.drain(stream)
        }
    }
    /// Whole-utterance offline decoding. No stream endpoints or
    /// streaming diarizer; the final pass reuses the meeting's speaker timeline.
    func batch(_ samples: [Float]) async throws -> [String: Any] {
        try await perform {
            guard let recognizer = self.recognizer else { throw CaptureError.message("Speech model is not loaded") }
            var options = nemo_speech_asr_recognition_options_default()
            options.enable_word_time_offsets = true
            options.enable_automatic_punctuation = true
            options.enable_speaker_diarization = false
            var result: OpaquePointer?
            try self.check(nemo_speech_asr_recognize_f32(recognizer, &options, samples, samples.count, 16000, &result))
            guard let result else { throw CaptureError.message("Batch recognition returned no result") }
            defer { nemo_speech_asr_result_destroy(result) }
            return self.event(result)
        }
    }
    func close(_ id: UUID) {
        queue.async { if let stream = self.streams.removeValue(forKey: id) { nemo_speech_asr_stream_close(stream) } }
    }
    private func drain(_ stream: OpaquePointer) throws -> [[String: Any]] {
        var events: [[String: Any]] = []
        while true {
            var result: OpaquePointer?
            try check(nemo_speech_asr_stream_next(stream, &result))
            guard let result else { break }
            defer { nemo_speech_asr_result_destroy(result) }
            guard nemo_speech_asr_result_alternative_count(result) > 0 else { continue }
            events.append(event(result))
        }
        return events
    }
    private func event(_ result: OpaquePointer) -> [String: Any] {
            let final = nemo_speech_asr_result_is_final(result)
            let transcript = nemo_speech_asr_result_transcript(result, 0).map { String(cString: $0) } ?? ""
            var words: [[String: Any]] = []
            for index in 0..<nemo_speech_asr_result_word_count(result, 0) {
                var word: [String: Any] = [
                    "word": nemo_speech_asr_result_word_text(result, 0, index).map { String(cString: $0) } ?? "",
                    "start": Double(nemo_speech_asr_result_word_start_time(result, 0, index)) / 1000,
                    "end": Double(nemo_speech_asr_result_word_end_time(result, 0, index)) / 1000]
                let speaker = nemo_speech_asr_result_word_speaker_tag(result, 0, index)
                if speaker > 0 { word["speaker"] = Int(speaker) }; words.append(word)
            }
            return ["type": final ? "transcript.completed" : "transcript.partial", "transcript": transcript,
                    "words": words, "audio_processed": Double(nemo_speech_asr_result_audio_processed(result))]
    }
    private func check(_ status: nemo_speech_asr_status) throws {
        guard status == NEMO_SPEECH_ASR_OK else {
            throw CaptureError.message(nemo_speech_asr_last_error().map { String(cString: $0) } ?? "Native speech inference failed")
        }
    }
    private func perform<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

@MainActor
final class SpeechConnection {
    private let runtime: SpeechRuntime
    private let id = UUID()
    var onEvent: (([String: Any]) -> Void)?
    var onFailure: ((Error) -> Void)?
    init(runtime: SpeechRuntime) { self.runtime = runtime }
    func connect() async throws { try await runtime.open(id) }
    func write(_ data: Data) async throws { for event in try await runtime.push(data, id: id) { onEvent?(event) } }
    func finish() async throws { for event in try await runtime.finish(id) { onEvent?(event) } }
    func close() { runtime.close(id) }
}
