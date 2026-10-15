import Foundation
import AVFoundation
import CoreML
import FluidAudio
import WorkScribeCore

struct ExtractedVoice {
    var segmentID: String
    var vector: [Float]
}
protocol VoiceExtracting: Sendable {
    func extract(meeting: Meeting, folder: URL) async throws -> [ExtractedVoice]
}

/// Separate actor: model inference and WAV IO never block the UI or speech engine.
actor VoiceEngine: VoiceExtracting {
    private var extractor: EmbeddingExtractor?
    private func load() throws -> EmbeddingExtractor {
        if let extractor { return extractor }
        let selected = RuntimeAssets.model("wespeaker_v2.mlmodelc")
        try RuntimeAssets.require(selected)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try MLModel(contentsOf: selected, configuration: configuration)
        let loaded = EmbeddingExtractor(embeddingModel: model)
        extractor = loaded
        return loaded
    }
    func embedding(samples: [Float]) throws -> [Float] {
        guard samples.count >= 48_000, samples.count <= 160_000 else { throw CaptureError.message("A voice sample needs three to ten seconds") }
        let energy = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        guard energy > 0.000001 else { throw CaptureError.message("Voice sample is too quiet") }
        let extractor = try load()
        // NVIDIA already supplies single-speaker spans. Mark the selected crop as
        // active rather than running a second, conflicting segmentation model.
        let vectors = try extractor.getEmbeddings(audio: samples, masks: [[Float](repeating: 1, count: 589)])
        guard let vector = vectors.first, vector.count == 256, vector.allSatisfy(\.isFinite),
              VoiceMatching.cosine(vector, vector) > 0.99 else { throw CaptureError.message("Invalid voice sample") }
        return vector
    }
    func readSamples(url: URL, start: Double, duration: Double) throws -> [Float] {
        guard start.isFinite, duration.isFinite, start >= 0, duration >= 3 else { throw CaptureError.message("Invalid voice sample range") }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1 else { throw CaptureError.message("Voice samples require 16 kHz mono audio") }
        let frame = AVAudioFramePosition(start * 16000)
        let count = AVAudioFrameCount(min(duration, 10) * 16000)
        guard frame + Int64(count) <= file.length else { throw CaptureError.message("Voice sample extends past recorded audio") }
        file.framePosition = frame
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { throw CaptureError.message("Couldn’t read voice sample") }
        var samples: [Float] = []
        samples.reserveCapacity(Int(count))
        while samples.count < Int(count) {
            try file.read(into: buffer, frameCount: count - AVAudioFrameCount(samples.count))
            guard buffer.frameLength > 0 else { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        guard samples.count == Int(count) else { throw CaptureError.message("Voice sample could not be read completely") }
        return samples
    }
    func extract(meeting: Meeting, folder: URL) async throws -> [ExtractedVoice] {
        var results: [ExtractedVoice] = []
        // Bound work per recording and retain coverage for segment-level corrections.
        let grouped = Dictionary(grouping: meeting.segments.filter { VoiceMatching.eligible($0, in: meeting) }) {
            $0.speaker + ":" + (meeting.assignment(for: $0)?.profileID ?? "unknown")
        }
        for key in grouped.keys.sorted() {
            for segment in grouped[key]!.sorted(by: { $0.end - $0.start > $1.end - $1.start }).prefix(3) {
                try Task.checkCancellation()
                guard ["system", "microphone", AppModel.plaudSource].contains(segment.source), let location = meeting.audioLocation(for: segment) else { continue }
                let duration = min(10, segment.end - segment.start)
                let start = segment.start - location.offset + max(0, (segment.end - segment.start - duration) / 2)
                let samples = try readSamples(url: folder.appendingPathComponent(location.file), start: start, duration: duration)
                // Quiet clips do not prevent other speakers being processed.
                guard samples.reduce(Float(0), { $0 + $1 * $1 }) / Float(samples.count) > 0.000001 else { continue }
                let vector = try embedding(samples: samples)
                results.append(ExtractedVoice(segmentID: segment.id, vector: vector))
            }
        }
        return results
    }
}
