import Foundation
import ImageIO
import WorkScribeCore

/// Single bounded utility lane: never decodes an image or runs inference on the editor/main actor.
actor NoteImageUnderstanding {
    static let shared = NoteImageUnderstanding()
    private let queue = DispatchQueue(label: "WorkScribe.note-images", qos: .utility)
    private var cached: [String: NoteImage] = [:]
    private var captionAttempts = Set<String>()
    private var epoch = 0

    func read(_ reference: NoteImage, note: URL, vault: URL) async -> NoteImage {
        guard let url = NoteImageContent.resolve(reference, note: note, vault: vault) else {
            var result = NoteImage(target:reference.target,path:reference.path); result.method = "unavailable"; return result
        }
        let key = url.path + ":" + ((try? FolderIndexer.fingerprint(url)) ?? "missing")
        if let value = cached[key] { var result = value; result.target = reference.target; result.path = reference.path; return result }
        let generation = epoch
        let result: NoteImage = await withCheckedContinuation { continuation in
            queue.async {
                let start = Date()
                var result = NoteImage(target:reference.target,path:reference.path)
                result.fingerprint = key
                // Bound decompression and input size, and respect orientation on camera images.
                guard NoteImageContent.isMaterialized(url), let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 25 * 1024 * 1024,
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 2048,
                        kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                    result.method = "unavailable"; continuation.resume(returning: result); return
                }
                result.text = String(FileExtractors.ocr(image).prefix(8000))
                result.method = result.text?.isEmpty == false ? "vision-ocr" : "no-readable-text"
                result.seconds = Date().timeIntervalSince(start)
                continuation.resume(returning: result)
            }
        }
        // Bounded in-memory cache only; clear when the meeting is purged.
        if cached.count >= 24 { cached.removeAll(); captionAttempts.removeAll() }
        if epoch == generation && result.method != "unavailable" { cached[key] = result }
        return result
    }
    /// Optional isolated libmtmd helper. A hard wall-clock deadline leaves OCR usable on slow Macs.
    func caption(_ reference: NoteImage, note: URL, vault: URL) async -> NoteImage {
        guard reference.method != "unavailable", reference.caption == nil, let url = NoteImageContent.resolve(reference, note: note, vault: vault) else { return reference }
        let key = reference.fingerprint ?? url.path
        guard captionAttempts.insert(key).inserted else {
            var result = cached[key] ?? reference; result.target = reference.target; result.path = reference.path; return result
        }
        let generation = epoch
        let env = ProcessInfo.processInfo.environment
        let base = RuntimeAssets.model("")
        let helper = env["WORKSCRIBE_IMAGE_HELPER"] ?? base.appendingPathComponent("vision/bin/image-caption").path
        let projector = env["WORKSCRIBE_IMAGE_PROJECTOR"] ?? base.appendingPathComponent("vision/mmproj-gemma-4-E2B-it-Q8_0.gguf").path
        let model = env["WORKSCRIBE_IMAGE_MODEL"] ?? base.appendingPathComponent("vision/gemma-4-E2B-it-Q4_0.gguf").path
        guard FileManager.default.isExecutableFile(atPath: helper), [helper, model, projector].allSatisfy({ RuntimeAssets.inspect(URL(fileURLWithPath: $0)) == .present }) else { return reference }
        guard RuntimeAssets.inspect(URL(fileURLWithPath: helper).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib")) == .present else { return reference }
        let value: NoteImage = await withCheckedContinuation { continuation in
            queue.async {
                var result = reference
                let process = Process(), pipe = Pipe(), completed = DispatchSemaphore(value: 0)
                process.executableURL = URL(fileURLWithPath: helper); process.arguments = [model, projector, url.path]
                process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
                process.terminationHandler = { _ in completed.signal() }
                let start = Date()
                do {
                    try process.run()
                    if completed.wait(timeout: .now() + 20) == .timedOut {
                        process.terminate()
                        if completed.wait(timeout: .now() + 1) == .timedOut && process.isRunning { kill(process.processIdentifier, SIGKILL); completed.wait() }
                    }
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let caption = String(decoding: data.prefix(4000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    if process.terminationStatus == 0, !caption.isEmpty {
                        result.caption = caption; result.method = "gemma4+vision-ocr"; result.seconds = (reference.seconds ?? 0) + Date().timeIntervalSince(start)
                    }
                } catch { /* OCR stays available. */ }
                continuation.resume(returning: result)
            }
        }
        if epoch == generation { cached[key] = value }
        return value
    }
    /// Reuse the matched, fast llama runtime for batches containing image evidence. Older speech
    /// SDK builds otherwise compile slow text kernels on every pass. Transcript stays on stdin.
    func enhance(_ plan: NotePlan) async -> String? {
        guard plan.targets.contains(where: { !$0.note.imageEvidence.isEmpty }) else { return nil }
        let env = ProcessInfo.processInfo.environment
        let base = RuntimeAssets.model("vision")
        let helper = env["WORKSCRIBE_IMAGE_HELPER"] ?? base.appendingPathComponent("bin/image-caption").path
        let model = env["WORKSCRIBE_IMAGE_MODEL"] ?? base.appendingPathComponent("gemma-4-E2B-it-Q4_0.gguf").path
        guard FileManager.default.isExecutableFile(atPath:helper), [helper, model].allSatisfy({ RuntimeAssets.inspect(URL(fileURLWithPath: $0)) == .present }) else { return nil }
        guard RuntimeAssets.inspect(URL(fileURLWithPath: helper).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib")) == .present else { return nil }
        let prompt = NotePrompt.gemma(NotePrompt.instruction(plan))
        return await withCheckedContinuation { continuation in
            queue.async {
                let process=Process(), input=Pipe(), output=Pipe(), done=DispatchSemaphore(value:0)
                process.executableURL=URL(fileURLWithPath:helper);process.arguments=["--text",model]
                process.standardInput=input;process.standardOutput=output;process.standardError=FileHandle.nullDevice
                process.terminationHandler={ _ in done.signal() }
                do {
                    try process.run()
                    try input.fileHandleForWriting.write(contentsOf:Data(prompt.utf8));try input.fileHandleForWriting.close()
                    if done.wait(timeout:.now()+30) == .timedOut {
                        process.terminate()
                        if done.wait(timeout:.now()+1) == .timedOut && process.isRunning { kill(process.processIdentifier,SIGKILL);done.wait() }
                    }
                    let data=output.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning:process.terminationStatus == 0 ? String(decoding:data,as:UTF8.self) : nil)
                } catch { continuation.resume(returning:nil) }
            }
        }
    }
    func clear() { epoch += 1; cached.removeAll(); captionAttempts.removeAll() }
}

extension AppModel {
    func readNoteImages(_ id: String) {
        guard let snapshot = meetingSnapshot(id), let document = snapshot.document,
              let root = retentionService?.vault.root else { return }
        NoteImageJobs.tasks[id]?.cancel()
        let task = Task { [weak self] in
            // Each image is published as soon as OCR is ready. The note generator handles conversation context.
            for note in (snapshot.notes ?? []).suffix(64) {
                for reference in note.images ?? [] {
                    guard !Task.isCancelled, let self, self.meetingSnapshot(id)?.retention != "purged" else { return }
                    let result = await NoteImageUnderstanding.shared.read(reference, note: URL(fileURLWithPath: document.path), vault: root)
                    guard !Task.isCancelled else { return }
                    @MainActor func publish(_ result: NoteImage) {
                        var changed = false
                        try? self.mutateMeeting(id) { meeting in
                            guard let i = meeting.notes?.firstIndex(where: { $0.id == note.id && $0.text == note.text }),
                                  let j = meeting.notes![i].images?.firstIndex(where: { $0.target == reference.target && $0.path == reference.path }),
                                  meeting.notes![i].images![j] != result else { return }
                            meeting.notes![i].images![j] = result
                            meeting.notes![i].revision = (meeting.notes![i].revision ?? 0) + 1
                            if meeting.notes![i].isImage && meeting.notes![i].imageEvidence.isEmpty && meeting.notes![i].userEdited != true { meeting.notes![i].enhanced = nil }
                            if meeting.notes![i].userEdited != true {
                                meeting.notes![i].enhancedFrom = nil
                                meeting.notes![i].enhancementState = "pending"
                            }
                            changed = true
                        }
                        if changed { self.notesChanged(id); NoteEnhancementScheduler.shared.schedule(id, model: self) }
                    }
                    publish(result)
                    let captioned = await NoteImageUnderstanding.shared.caption(result, note: URL(fileURLWithPath: document.path), vault: root)
                    if !Task.isCancelled && captioned != result { publish(captioned) }
                }
            }
        }
        NoteImageJobs.tasks[id] = task
    }
    func cancelNoteImages(_ id: String) { NoteImageJobs.tasks.removeValue(forKey: id)?.cancel() }
    func finishNoteImages(_ id: String) async {
        guard let task = NoteImageJobs.tasks[id] else { return }
        // Finishing a meeting never waits for a backlog of expensive image captions.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let completion = ImageCompletion(continuation)
            Task { await task.value; completion.finish() }
            DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+5) { completion.finish() }
        }
        task.cancel(); NoteImageJobs.tasks[id] = nil
    }
}

@MainActor private enum NoteImageJobs {
    static var tasks: [String: Task<Void, Never>] = [:]
}

private final class ImageCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
    func finish() {
        let value = lock.withLock { let value = continuation; continuation = nil; return value }
        value?.resume()
    }
}
