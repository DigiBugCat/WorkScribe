#if WORKSCRIBE_PLAUD
import Foundation
@preconcurrency import AVFoundation
import WorkScribeCore
import WorkScribePlaud

/// Turns recordings saved from a Note Pro into ordinary WorkScribe meetings.
/// Imports share the warm speech engine, so they pause while a live recording
/// runs and resume afterwards from the start of the interrupted file.
@MainActor extension AppModel {

    func importPlaud(_ recordings: [PlaudSavedRecording]) {
        let known = Set(library.compactMap(\.recordingTrigger)).union(importQueue.map { "plaud:" + $0.id })
        let fresh = recordings.filter { !known.contains("plaud:" + $0.id) }
        guard !fresh.isEmpty else {
            if importQueue.isEmpty { importStatus = "These recordings are already in Recent." }
            return
        }
        if importQueue.isEmpty { importDone = 0; importTotal = 0; importFailures = 0 }
        importQueue += fresh; importTotal += fresh.count
        runImports()
    }

    var importActive: Bool { !importQueue.isEmpty }

    func runImports() {
        guard importTask == nil, !busy, !importQueue.isEmpty else {
            if busy && !importQueue.isEmpty { importStatus = "Adding Note Pro recordings to Recent after this recording." }
            return
        }
        importTask = Task { [weak self] in
            guard let self else { return }
            defer { importTask = nil }
            while let next = importQueue.first, !Task.isCancelled, !busy {
                importStatus = "Transcribing Note Pro recording \(importDone + 1) of \(importTotal) for Recent…"
                do {
                    try await importOne(next)
                    importQueue.removeFirst(); importDone += 1
                } catch is CancellationError {
                    importStatus = "Adding Note Pro recordings to Recent after this recording."
                    return
                } catch {
                    importQueue.removeFirst(); importDone += 1; importFailures += 1
                }
            }
            if importQueue.isEmpty && importTotal > 0 {
                let added = importTotal - importFailures
                importStatus = importFailures == 0
                    ? "Added \(added) Note Pro \(added == 1 ? "recording" : "recordings") to Recent."
                    : "Added \(added) of \(importTotal) to Recent. \(importFailures) couldn’t be transcribed; the audio is still in the saved files."
            }
        }
    }

    /// Called before a live recording claims the speech engine.
    func pauseImports() async {
        guard let task = importTask else { return }
        task.cancel(); await task.value
    }

    private func importOne(_ recording: PlaudSavedRecording) async throws {
        try await prepareSpeech()
        let file = try AVAudioFile(forReading: recording.audioURL)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        let fileDate = (try? recording.audioURL.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        let started = recording.recordedAt ?? fileDate

        var entry = Meeting(title: "Note Pro · \(started.formatted(date: .abbreviated, time: .shortened))", titleOrigin: "pending")
        entry.startedAt = started
        entry.recordingTrigger = "plaud:" + recording.id
        entry.sourceOffsets = [Self.plaudSource: 0]
        let folder = try store.directory(entry.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            try FileManager.default.copyItem(at: recording.audioURL, to: folder.appendingPathComponent(Self.plaudSource + ".wav"))
            entry.segments = try await transcribe(file)
            entry.status = "complete"
            entry.endedAt = started.addingTimeInterval(seconds)
            try store.save(entry)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            await runtime.closeStreams()
            throw error
        }
        await runtime.closeStreams()
        library = store.list()
        scheduleTitle(id: entry.id, final: true)
        analyzeVoices(id: entry.id)
    }

    private func transcribe(_ file: AVAudioFile) async throws -> [Segment] {
        let connection = SpeechConnection(runtime: runtime)
        var segments: [Segment] = []
        var end = 0.0
        connection.onEvent = { event in
            guard (event["type"] as? String)?.hasSuffix(".completed") == true else { return }
            let parsed = TranscriptParser.segments(event: event, source: Self.plaudSource, offset: 0, fallbackStart: end)
            segments += parsed
            if let last = parsed.last { end = last.end }
        }
        try await connection.connect()
        defer { connection.close() }
        let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: output) else {
            throw CaptureError.message("This recording’s audio format can’t be read")
        }
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)!
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: input)
            let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / input.format.sampleRate)) + 256
            let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity)!
            var used = false, error: NSError?
            converter.convert(to: buffer, error: &error) { _, state in
                if used { state.pointee = .noDataNow; return nil }
                used = true; state.pointee = .haveData; return input
            }
            if let error { throw error }
            try await connection.write(Data(bytes: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * 2))
        }
        try Task.checkCancellation()
        try await connection.finish()
        return segments
    }
}

#endif

// Existing recorder audio can still be read without the proprietary device SDK.
@MainActor extension AppModel {
    nonisolated static let plaudSource = "recorder"
#if !WORKSCRIBE_PLAUD
    var importActive: Bool { false }
    func runImports() {}
    func pauseImports() async {}
#endif
}
