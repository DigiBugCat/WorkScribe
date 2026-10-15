import Foundation
@preconcurrency import AVFoundation
import WorkScribeCore

protocol BatchTranscribing: Sendable {
    func transcribe(url: URL, offset: Double, progress: @escaping @Sendable (Double) async throws -> Void) async throws -> [TranscriptWord]
}

/// Bounded memory and acoustic context, with disjoint ownership of overlapping
/// windows. Only reads the existing track; no clips or second audio archive are written.
final class NativeBatchTranscriber: BatchTranscribing, @unchecked Sendable {
    let runtime: SpeechRuntime
    init(runtime: SpeechRuntime) { self.runtime = runtime }
    func transcribe(url: URL, offset: Double, progress: @escaping @Sendable (Double) async throws -> Void) async throws -> [TranscriptWord] {
        try await runtime.start()
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        let duration = Double(file.length) / rate
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: file.processingFormat, to: format)
        let window = 60.0, context = 4.0
        var words: [TranscriptWord] = []
        for start in stride(from: 0.0, to: duration, by: window) {
            try Task.checkCancellation()
            let end = min(start + window, duration)
            let readStart = max(0, start - context), readEnd = min(duration, end + context)
            file.framePosition = AVAudioFramePosition((readStart * rate).rounded())
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(((readEnd - readStart) * rate).rounded()))!
            try file.read(into: buffer)
            let audio: AVAudioPCMBuffer
            if rate == 16000 && file.processingFormat.channelCount == 1 { audio = buffer }
            else {
                guard let converter else { throw CaptureError.message("Saved audio format cannot be converted") }
                converter.reset()
                let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / rate)) + 256)!
                var used = false, error: NSError?
                converter.convert(to: output, error: &error) { _, state in
                    if used { state.pointee = .endOfStream; return nil }
                    used = true; state.pointee = .haveData; return buffer
                }
                if let error { throw error }
                audio = output
            }
            let samples = Array(UnsafeBufferPointer(start: audio.floatChannelData![0], count: Int(audio.frameLength)))
            let event = try await runtime.batch(samples)
            try Task.checkCancellation()
            let decoded = TranscriptParser.timedWords(event: event, offset: offset + readStart, fallbackStart: offset + readStart)
            words += decoded.filter {
                let midpoint = ($0.start + $0.end) / 2 - offset
                return midpoint >= start && (midpoint < end || end == duration)
            }.map { TranscriptWord(text: $0.text, start: $0.start, end: $0.end) }
            try await progress(end / max(1, duration))
            if ProcessInfo.processInfo.environment["WORKSCRIBE_REPLAY_PROGRESS"] != nil {
                FileHandle.standardError.write(Data("Polished \(Int(end))/\(Int(duration)) seconds\n".utf8))
            }
        }
        return words
    }
}

extension AppModel {
    /// A commit fence covers resume, purge and edits while native inference is running.
    /// Only transcript fields are replaced; live user edits never come from the snapshot.
    func polishTranscript(_ id: String, audioFolder: URL? = nil) async throws {
        guard let snapshot = meetingSnapshot(id), let ended = snapshot.endedAt,
              snapshot.transcriptPolishedForEnd != ended,
              snapshot.retention != "purged", snapshot.retention != "purging" else { return }
        let generation = recordingGeneration
        let folder = try audioFolder ?? store.directory(id)
        let sessions = snapshot.recordingSessions ?? [RecordingSession(id: "initial", start: 0, sourceOffsets: snapshot.sourceOffsets ?? [:])]
        let inputs = sessions.flatMap { session in
            ["microphone", "system", "recorder"].compactMap { source -> (RecordingSession, String, URL, Double)? in
                let url = folder.appendingPathComponent(session.audioFile(source))
                // Only tracks that actually started have a source clock. An unused
                // microphone file can contain minutes of zeros; it is not a capture.
                let offset = session.sourceOffsets[source] ?? (session.id == "initial" ? snapshot.sourceOffsets?[source] : nil)
                guard let offset, FileManager.default.fileExists(atPath: url.path) else { return nil }
                return (session, source, url, offset)
            }
        }
        guard !inputs.isEmpty else { return } // Legacy text-only imports and deterministic tests.
        if meeting?.id == id { message = "Polishing the transcript…" }
        let transcriber = batchTranscriber ?? NativeBatchTranscriber(runtime: runtime)
        var replacement: [Segment] = [], aliases = snapshot.transcriptAliases ?? [:]
        var replaced = Set<String>()
        for (index, input) in inputs.enumerated() {
            let (session, source, url, offset) = input
            let original = snapshot.segments.filter { $0.source == source && $0.start >= session.start && (session.end == nil || $0.start < session.end!) }
            let words = try await transcriber.transcribe(url: url, offset: offset) { fraction in
                try await MainActor.run {
                    guard self.recordingGeneration == generation,
                          let current = self.meetingSnapshot(id), current.endedAt == ended,
                          current.retention != "purged", current.retention != "purging" else { throw CancellationError() }
                    if self.meeting?.id == id, self.meeting?.endedAt == ended {
                        self.finalizationProgress = 0.35 + 0.35 * (Double(index) + fraction) / Double(inputs.count)
                    }
                }
            }
            try Task.checkCancellation()
            guard recordingGeneration == generation, let current = meetingSnapshot(id), current.endedAt == ended,
                  current.recordingSessions?.last?.id == snapshot.recordingSessions?.last?.id,
                  current.retention != "purged", current.retention != "purging" else { return }
            let unknown = session.id == "initial" ? source + ":unknown" : session.id + ":" + source + ":unknown"
            let final = FinalTranscript.aligned(words, source: source, originals: original, unknownSpeaker: unknown)
            // Empty output must never erase recognized speech. Fail visibly and retain the live transcript.
            guard !final.isEmpty || original.isEmpty else { throw CaptureError.message("The transcript polish returned no speech") }
            for old in original {
                replaced.insert(old.id)
                if !final.contains(where: { $0.id == old.id }), let closest = final.min(by: { abs($0.start - old.start) < abs($1.start - old.start) }) {
                    aliases[old.id] = closest.id
                }
            }
            replacement += final
        }
        try mutateMeeting(id) { current in
            current.segments.removeAll { replaced.contains($0.id) }
            current.segments += replacement
            for segment in replacement where current.segmentAssignments?[segment.id] == nil {
                if let original = snapshot.segments.first(where: {
                    $0.source == segment.source && $0.speaker == segment.speaker &&
                    segment.start >= $0.start - 2 && segment.start <= $0.end + 2
                }), let assignment = current.segmentAssignments?[original.id] {
                    current.segmentAssignments?[segment.id] = assignment
                }
            }
            for segment in replacement { aliases.removeValue(forKey: segment.id) }
            current.transcriptAliases = aliases
            current.transcriptPolishedForEnd = ended
            current.partials = [:]; current.partialIDs = [:]; current.partialSpeakers = [:]
            // Old AI lines were grounded in provisional recognition; the final pass gets
            // fresh evidence even if an anchor survived. User-written AI edits stay protected.
            for i in (current.notes ?? []).indices where current.notes![i].userEdited != true && current.notes![i].fromAnswer == nil {
                current.notes![i].enhancedFrom = nil
            }
        }
        notesChanged(id)
    }
}
