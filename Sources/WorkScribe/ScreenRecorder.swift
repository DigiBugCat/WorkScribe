import AppKit
@preconcurrency import AVFoundation
import CoreImage
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
@preconcurrency import Vision
import WorkScribeCore

/// What screen capture is doing, for the UI.
enum ScreenCaptureState: Equatable {
    case off
    case starting
    case recording
    case paused
    /// A private app (deny list) is frontmost: frames aren't read or indexed.
    case privateApp(String)
    /// Not attempted: disabled, or Screen Recording permission missing.
    case unavailable(String)
    /// Capture stopped or never started; audio keeps recording.
    case failed(String)

    var label: String {
        switch self {
        case .off: "Screen capture off"
        case .starting: "Starting screen capture…"
        case .recording: "Reading screen text"
        case .paused: "Screen capture paused"
        case .privateApp(let name): "Screen text hidden while \(name) is in front"
        case .unavailable(let why): why
        case .failed(let why): "Screen capture stopped: \(why)"
        }
    }
    var isCapturing: Bool {
        switch self { case .recording, .paused, .privateApp: true; default: false }
    }
}

enum ScreenCaptureTarget: String, CaseIterable {
    /// The main display, minus WorkScribe's own windows and private apps.
    case display
    /// The call's (or else the frontmost app's) largest window; falls back to the display.
    case window
}

struct ScreenCaptureSettings {
    var target: ScreenCaptureTarget = .display
    /// The video's frame rate ceiling. ScreenCaptureKit only delivers frames when something changed.
    var framesPerSecond = 2
    /// Wide enough for Vision to read 11-pt UI text on a typical display.
    var maximumWidth = 1920
    /// Base interval for pixel-gated scene embeddings. Pressure increases this interval.
    var sampleInterval = 2.5
    var deniedBundleIDs = ScreenPrivacy.defaultDeniedBundleIDs
}

/// Reads transient screen frames for scene detection and OCR. Only derived text and
/// scene metadata are persisted; no video, thumbnail, or keyframe is recorded.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let folder: URL
    let meetingID: String
    let meetingStart: Date
    let videoFile: String
    let previousMoments: [ScreenMoment]
    let settings: ScreenCaptureSettings
    let store: MeetingStore
    /// Called on the main queue.
    var onState: ((ScreenCaptureState) -> Void)?
    /// Called on the main queue with every moment so far, whenever a moment starts or ends.
    var onMoments: (([ScreenMoment]) -> Void)?

    private let lock = NSLock()
    private let captureQueue = DispatchQueue(label: "WorkScribe.screen-capture", qos: .userInitiated)
    private var stream: SCStream?
    private var firstPTS: CMTime?
    private var offset: Double?
    private var sampler: KeyframeSampler
    private var builder = ScreenSceneDetector()
    private let embedder: CoreMLEmbedder?
    private var pressure: RecordingPressure = .normal
    private var generation = 0
    private var frames: [String: CGImage] = [:]
    private var savedRepresentative: (scene: String, frame: String)?
    private var lastSignature: FrameSignature?
    private var ocrTask: Task<Void, Never>?
    private var inferenceRetryAt: Double = 0
    private var sceneFailure: String?
    private var persistedAt: Double = -.infinity

    private var paused = false
    private var stopped = false
    private var analyzing: Task<Void, Never>?
    private var state: ScreenCaptureState = .off
    private var targetDescription = "display"
    private var failure: String?
    private var latestFrame: (image: CGImage, at: Double, captured: Date)?
    private var display: SCDisplay?
    private var observers: [NSObjectProtocol] = []
    private var frontmost: (name: String?, bundleID: String?, pid: pid_t?) = (nil, nil, nil)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    init(folder: URL, meetingID: String, meetingStart: Date, store: MeetingStore, settings: ScreenCaptureSettings = ScreenCaptureSettings(), videoFile: String = ScreenFiles.video, embedder: CoreMLEmbedder? = CoreMLEmbedder.bundled()) {
        self.folder = folder; self.meetingID = meetingID; self.meetingStart = meetingStart
        self.store = store; self.settings = settings; self.videoFile = videoFile
        self.embedder = embedder?.supportsImages == true ? embedder : nil
        self.previousMoments = store.loadScreenMoments(meetingID)
        sampler = KeyframeSampler(interval: settings.sampleInterval)
    }

    // MARK: Lifecycle

    /// Starts capture. Throws when it can't (no permission, no display): the caller records audio only.
    @MainActor
    func start(callBundleID: String? = nil) async throws -> ScreenCaptureInfo {
        set(.starting)
        trackFrontmost()
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let own = Bundle.main.bundleIdentifier
        var filter: SCContentFilter?
        var size = CGSize.zero, scale: CGFloat = 1
        if settings.target == .window, !ScreenPrivacy.isDenied(callBundleID ?? frontmostBundle(excluding: own), list: settings.deniedBundleIDs), let window = Self.window(in: content, bundleID: callBundleID ?? frontmostBundle(excluding: own), own: own) {
            filter = SCContentFilter(desktopIndependentWindow: window)
            size = window.frame.size
            targetDescription = "window:\(window.owningApplication?.bundleIdentifier ?? "unknown")"
        }
        if filter == nil {
            let main = CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == main }) ?? content.displays.first else {
                throw CaptureError.message("No display available for screen capture")
            }
            self.display = display
            filter = displayFilter(display, content: content)
            size = CGSize(width: display.width, height: display.height)
            targetDescription = "display"
        }
        scale = CGFloat(filter!.pointPixelScale)
        let pixels = CGSize(width: size.width * scale, height: size.height * scale)
        let factor = min(1, CGFloat(settings.maximumWidth) / max(pixels.width, 1))
        let width = max(2, Int(pixels.width * factor) / 2 * 2), height = max(2, Int(pixels.height * factor) / 2 * 2)

        let config = SCStreamConfiguration()
        config.width = width; config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(settings.framesPerSecond, 1)))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 5
        config.capturesAudio = false

        let stream = SCStream(filter: filter!, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        self.stream = stream
        do { try await stream.startCapture() } catch {
            self.stream = nil
            throw error
        }
        if targetDescription == "display" { watchLaunches() }
        set(.recording)
        return info(state: "recording")
    }

    /// Pausing drops frames: nothing is written, read or indexed until resumed.
    func setPaused(_ value: Bool) {
        lock.lock()
        guard !stopped, paused != value else { lock.unlock(); return }
        paused = value; generation += 1
        frames.removeAll(); lastSignature = nil
        latestFrame = nil
        if value { builder.close(at: now()); sampler.reset() }
        let moments = builder.all
        lock.unlock()
        if value { ScreenContext.shared.clear(); persist(moments) }
        set(value ? .paused : .recording)
    }

    /// Stops capture and discards transient frames.
    func stop() async -> (info: ScreenCaptureInfo, moments: [ScreenMoment]) {
        let stream: SCStream? = lock.withLock { stopped = true; generation += 1; latestFrame = nil; defer { self.stream = nil }; return self.stream }
        if let stream { try? await stream.stopCapture() }
        await MainActor.run { observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers = [] }
        // Drain capture delivery; in-flight inference has already lost its generation.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in captureQueue.async { done.resume() } }
        let pending = lock.withLock { analyzing }
        pending?.cancel(); ocrTask?.cancel()
        // Core ML/Vision may be in an uninterruptible driver call. Invalidate publication now;
        // let cleanup wait off the recording finalization path, never hold up transcript finalization.
        let model = embedder
        Task.detached(priority: .background) { await pending?.value; await model?.release() }
        let end = now()
        let (moments, failed) = lock.withLock { (builder.finish(at: end), failure != nil) }
        ScreenContext.shared.clear()
        persist(moments)
        lock.withLock { frames.removeAll() }
        let final = info(state: failed ? "failed" : "complete", moments: moments.count)
        if !failed { set(.off) }
        return (final, store.loadScreenMoments(meetingID))
    }

    private func info(state: String, moments: Int? = nil) -> ScreenCaptureInfo {
        lock.lock(); defer { lock.unlock() }
        return ScreenCaptureInfo(file: nil, offset: offset,
                                 target: targetDescription, state: state, failure: failure ?? sceneFailure,
                                 momentCount: previousMoments.count + (moments ?? builder.all.count))
    }

    // MARK: SCStream

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); generation += 1; failure = error.localizedDescription; builder.close(at: now()); let moments = builder.all; lock.unlock()
        ScreenContext.shared.clear()
        persist(moments)
        set(.failed(error.localizedDescription))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, Self.isComplete(sampleBuffer),
              let pixels = sampleBuffer.imageBuffer else { return }
        let pts = sampleBuffer.presentationTimeStamp
        lock.lock()
        guard !stopped, !paused else { lock.unlock(); return }
        if firstPTS == nil {
            firstPTS = pts
            let age = max(0, CMClockGetTime(CMClockGetHostTimeClock()).seconds - pts.seconds)
            offset = Date().addingTimeInterval(-age).timeIntervalSince(meetingStart)
        }
        let time = (offset ?? Date().timeIntervalSince(meetingStart)) + (firstPTS.map { (pts - $0).seconds } ?? 0)
        let front = frontmost
        if ScreenPrivacy.isDenied(front.bundleID, list: settings.deniedBundleIDs) {
            builder.close(at: time); sampler.reset(); latestFrame = nil; frames.removeAll(); generation += 1
            let moments = builder.all
            lock.unlock()
            ScreenContext.shared.clear(); persist(moments)
            set(.privateApp(front.name ?? "a private app"))
            return
        }
        let budget = workBudget()
        sampler.interval = budget.sampleInterval
        guard analyzing == nil, sampler.isDue(time) else { builder.extend(to: time); lock.unlock(); return }
        let token = generation
        let task = Task.detached(priority: .background) { [weak self] in
            await self?.analyze(pixels, time: time, front: front, generation: token)
            self?.lock.withLock { self?.analyzing = nil }
        }
        analyzing = task
        lock.unlock()
        if case .privateApp = currentState() { set(.recording) }
    }

    private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    // MARK: Scenes and lazy OCR

    private func workBudget() -> ScreenWorkBudget {
        ScreenWorkBudget(pressure: pressure, thermalLevel: ProcessInfo.processInfo.thermalState.rawValue,
                         baseInterval: settings.sampleInterval)
    }

    func setPressure(_ value: RecordingPressure) {
        lock.withLock {
            pressure = value
            if !workBudget().embeddings { sampler.reset(); generation += 1 }
        }
    }

    /// On-demand text freezes the representative before reading it. Scene membership still evolves.
    func freezeRepresentative(_ id: String) {
        lock.withLock { builder.freezeRepresentative(id); persist(builder.all) }
    }

    private func analyze(_ pixels: CVPixelBuffer, time: Double,
                         front: (name: String?, bundleID: String?, pid: pid_t?), generation token: Int) async {
        let image = CIImage(cvPixelBuffer: pixels)
        guard let frame = ciContext.createCGImage(image, from: image.extent), let signature = FrameSignature(image: frame) else { return }
        let eligible: Bool = lock.withLock {
            guard generation == token, !paused, !stopped, front.pid == frontmost.pid,
                  !ScreenPrivacy.isDenied(frontmost.bundleID, list: settings.deniedBundleIDs) else { return false }
            latestFrame = (frame, time, Date())
            let changed = sampler.consider(signature, at: time)
            guard workBudget().embeddings, time >= inferenceRetryAt else {
                // The first permitted look must embed even when the screen stayed unchanged during deferral.
                sampler.reset(); return false
            }
            return changed || builder.needsConfirmation
        }
        guard eligible, !Task.isCancelled, let embedder else { return }
        let vector: [Float]
        do { vector = try await embedder.image(frame) }
        catch {
            lock.withLock { inferenceRetryAt = time + 30; sceneFailure = "Scene detection deferred: " + error.localizedDescription; sampler.reset() }
            return
        }
        let window = front.pid.flatMap(Self.windowTitle)
        lock.withLock {
            guard generation == token, !Task.isCancelled, !paused, !stopped, workBudget().embeddings,
                  front.pid == frontmost.pid, !ScreenPrivacy.isDenied(frontmost.bundleID, list: settings.deniedBundleIDs) else { return }
            sceneFailure = nil
            let previousID = builder.open?.id
            let previousFrame = savedRepresentative?.frame
            let id = UUID().uuidString
            let stability = lastSignature.map { 1 - FrameChangeDetector.difference($0, signature).fraction } ?? 0
            lastSignature = signature
            frames[id] = frame
            _ = builder.add(.init(time: time, vector: vector, frameID: id, stability: stability,
                                  app: front.name, bundleID: front.bundleID, window: window), modelID: embedder.modelID)
            // Keep only a few current representatives until OCR has read them.
            if let scene = builder.open, let frameID = builder.representatives[scene.id] {
                savedRepresentative = (scene.id, frameID)
            }
            let recent = Set(builder.representatives.values)
            frames = frames.filter { recent.contains($0.key) }
            if previousID != builder.open?.id || previousFrame != savedRepresentative?.frame || time - persistedAt >= 15 {
                persistedAt = time; persist(builder.all)
            }
        }
        scheduleOCR()
    }

    private func scheduleOCR() {
        lock.withLock {
            guard ocrTask == nil, workBudget().ocr, !paused, !stopped,
                  let scene = builder.all.first(where: { scene in
                      frames[builder.representatives[scene.id] ?? ""] != nil &&
                          store.loadScreenMoments(meetingID).first(where: { $0.id == scene.id })?.ocrState == nil
                  }), let frameID = builder.representatives[scene.id], let frame = frames[frameID] else { return }
            builder.freezeRepresentative(scene.id)
            persist(builder.all)
            ocrTask = Task.detached(priority: .background) { [weak self] in
                guard let self else { return }
                _ = await ScreenSceneText.shared.read(scene.id, meetingID: self.meetingID, store: self.store, image: frame, allowed: { [weak self] in
                    guard let self else { return false }
                    return self.lock.withLock { !self.stopped && !self.paused && self.workBudget().ocr && !ScreenPrivacy.isDenied(self.frontmost.bundleID, list: self.settings.deniedBundleIDs) }
                })
                self.lock.withLock { self.frames.removeValue(forKey: frameID); self.ocrTask = nil; self.persist(self.builder.all) }
            }
        }
    }

    /// A current, permitted frame only. Recheck the front app and lifecycle under the same lock.
    func grabMoment() throws -> GrabMoment {
        try lock.withLock {
            guard !paused, !stopped, state == .recording,
                  !ScreenPrivacy.isDenied(frontmost.bundleID, list: settings.deniedBundleIDs),
                  let frame = latestFrame else {
                throw CaptureError.message("No current permitted screen frame. Screen awareness must be recording.")
            }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                throw CaptureError.message("Could not encode the screen image")
            }
            CGImageDestinationAddImage(destination, frame.image, nil)
            guard CGImageDestinationFinalize(destination) else { throw CaptureError.message("Could not encode the screen image") }
            return GrabMoment(data: data as Data, at: frame.at)
        }
    }

    private func persist(_ moments: [ScreenMoment]) {
        let combined: [ScreenMoment] = ScreenFiles.mutationLock.withLock {
            let saved = Dictionary(uniqueKeysWithValues: store.loadScreenMoments(meetingID).map { ($0.id, $0) })
            let merged = (previousMoments + moments).map { original -> ScreenMoment in
                var scene = original; scene.thumbnail = nil; scene.keyframe = nil
                guard let read = saved[scene.id], read.ocrState != nil, read.representativeTime == scene.representativeTime else { return scene }
                scene.text = read.text; scene.lines = read.lines; scene.ocrState = read.ocrState
                return scene
            }
            do { try store.saveScreenMoments(merged, id: meetingID) } catch { return [] }
            return merged
        }
        let callback = onMoments
        DispatchQueue.main.async { callback?(combined) }
    }

    // MARK: Helpers

    private func now() -> Double { Date().timeIntervalSince(meetingStart) }

    private func set(_ value: ScreenCaptureState) {
        lock.lock(); let changed = state != value; state = value; lock.unlock()
        guard changed else { return }
        let callback = onState
        DispatchQueue.main.async { callback?(value) }
    }

    private func currentState() -> ScreenCaptureState { lock.withLock { state } }

    @MainActor
    private func trackFrontmost() {
        setFrontmost(NSWorkspace.shared.frontmostApplication)
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                           object: nil, queue: .main) { [weak self] note in
            self?.setFrontmost(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        })
    }

    private func setFrontmost(_ app: NSRunningApplication?) {
        let value = (app?.localizedName, app?.bundleIdentifier, app?.processIdentifier)
        lock.withLock {
            if frontmost.pid != value.2 {
                latestFrame = nil; generation += 1; sampler.reset(); lastSignature = nil; ScreenContext.shared.clear()
                if ScreenPrivacy.isDenied(value.1, list: settings.deniedBundleIDs) {
                    builder.close(at: now()); frames.removeAll(); ScreenContext.shared.clear()
                }
            }
            frontmost = value
        }
    }

    @MainActor
    private func frontmostBundle(excluding own: String?) -> String? {
        let bundle = lock.withLock { frontmost.bundleID }
        return bundle == own ? nil : bundle
    }

    /// A private app launched mid-meeting: exclude its windows from the video too.
    @MainActor
    private func watchLaunches() {
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                                           object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  ScreenPrivacy.isDenied(app.bundleIdentifier, list: settings.deniedBundleIDs) else { return }
            Task { await self.refreshFilter() }
        })
    }

    private func refreshFilter() async {
        guard let display, let stream = lock.withLock({ self.stream }),
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return }
        try? await stream.updateContentFilter(displayFilter(display, content: content))
    }

    private func displayFilter(_ display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        let own = Bundle.main.bundleIdentifier
        let excluded = content.applications.filter { app in
            app.bundleIdentifier == own || app.processID == ProcessInfo.processInfo.processIdentifier
                || ScreenPrivacy.isDenied(app.bundleIdentifier, list: settings.deniedBundleIDs)
        }
        return SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
    }

    /// The largest normal on-screen window of `bundleID`.
    private static func window(in content: SCShareableContent, bundleID: String?, own: String?) -> SCWindow? {
        guard let bundleID, bundleID != own else { return nil }
        return content.windows
            .filter { $0.owningApplication?.bundleIdentifier == bundleID && $0.windowLayer == 0 && $0.isOnScreen
                && $0.frame.width >= 200 && $0.frame.height >= 150 }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// The front window title of `pid` (needs Screen Recording permission, which capture already has).
    static func windowTitle(pid: pid_t) -> String? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.first { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .flatMap { $0[kCGWindowName as String] as? String }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Vision OCR for screen frames: document recognition (macOS 26: paragraphs, tables, lists) with line boxes, falling
/// back to plain text recognition.
enum ScreenOCR {
    static func read(_ image: CGImage) async -> (text: String, lines: [ScreenTextLine]) {
        do {
            let documents = try await RecognizeDocumentsRequest().perform(on: image)
            let lines = documents.flatMap { $0.document.text.lines }
            if !lines.isEmpty { return convert(lines) }
            let text = documents.map { $0.document.text.transcript }.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (text, []) }
        } catch {}
        do {
            var request = RecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            return convert(try await request.perform(on: image))
        } catch { return ("", []) }
    }

    private static func convert(_ observations: [RecognizedTextObservation]) -> (text: String, lines: [ScreenTextLine]) {
        let lines = observations.compactMap { line -> ScreenTextLine? in
            let text = line.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let box = line.boundingBox
            return ScreenTextLine(text: text, x: box.origin.x, y: box.origin.y, width: box.width, height: box.height)
        }
        return (lines.map(\.text).joined(separator: "\n"), lines)
    }
}
