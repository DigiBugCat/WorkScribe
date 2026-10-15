import Foundation

// Screen awareness records meeting-scoped video and visual scenes. A scene has a representative frame,
// a vision embedding, and optional lazy OCR. The existing ScreenMoment wire format remains compatible.
// Capture, embedding and OCR live in the app target; temporal policy is platform-neutral.

/// One recognized line, with its box in normalized image coordinates (Vision's: origin bottom-left, 0…1).
public struct ScreenTextLine: Codable, Equatable, Sendable {
    public var text: String
    public var x: Double, y: Double, width: Double, height: Double
    public init(text: String, x: Double, y: Double, width: Double, height: Double) {
        self.text = text; self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// A visual scene. Older recordings may contain text-derived moments without an embedding.
public struct ScreenMoment: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    /// Meeting seconds, on the same clock as `Segment.start` (0 = `Meeting.startedAt`).
    public var start: Double
    public var end: Double
    public var text: String
    public var lines: [ScreenTextLine]?
    /// The frontmost app and its window title when the moment began, when known.
    public var app: String?
    public var bundleID: String?
    public var window: String?
    /// A small JPEG, relative to the meeting folder ("screen/<id>.jpg").
    public var thumbnail: String?
    /// Kept frames merged into this moment.
    public var frames: Int
    public var embedding: [Float]?
    public var embeddingModelID: String?
    public var representativeTime: Double?
    public var keyframe: String?
    /// nil = deferred; reading/complete/failed. A representative is frozen before its one OCR attempt.
    public var ocrState: String?

    public init(id: String = UUID().uuidString, start: Double, end: Double, text: String, lines: [ScreenTextLine]? = nil,
                app: String? = nil, bundleID: String? = nil, window: String? = nil, thumbnail: String? = nil, frames: Int = 1) {
        self.id = id; self.start = start; self.end = end; self.text = text; self.lines = lines; self.app = app
        self.bundleID = bundleID; self.window = window; self.thumbnail = thumbnail; self.frames = frames
    }

    /// "Keynote — Q3 plan.key", or nil when nothing is known.
    public var context: String? {
        let parts = [app, window].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let unique = parts.count == 2 && parts[0] == parts[1] ? [parts[0]] : parts
        return unique.isEmpty ? nil : unique.joined(separator: " — ")
    }

    /// What gets embedded and keyword-indexed: the app/window line, then the screen text.
    public var searchText: String { [context, text].compactMap { $0 }.joined(separator: "\n") }
}

/// Per-meeting screen recording state (absent on audio-only and older recordings).
public struct ScreenCaptureInfo: Codable, Equatable, Sendable {
    /// The video, relative to the meeting folder; nil when it was never written or has been deleted.
    public var file: String?
    /// Meeting seconds at the video's t = 0 (like `Meeting.sourceOffsets` for audio): video time = meeting time − offset.
    public var offset: Double?
    /// "display" or "window:<bundle id>".
    public var target: String
    /// recording · complete · failed · deleted
    public var state: String
    public var failure: String?
    public var momentCount: Int
    public var deletedAt: Date?
    public init(file: String? = nil, offset: Double? = nil, target: String = "display", state: String = "recording",
                failure: String? = nil, momentCount: Int = 0, deletedAt: Date? = nil) {
        self.file = file; self.offset = offset; self.target = target; self.state = state; self.failure = failure
        self.momentCount = momentCount; self.deletedAt = deletedAt
    }
}

/// Where the screen files of a meeting live, next to transcript.json.
public enum ScreenFiles {
    public static let video = "screen.mov"
    public static let moments = "screen-moments.json"
    public static let thumbnails = "screen"
    public static func thumbnail(_ momentID: String) -> String { "\(thumbnails)/\(momentID).jpg" }
}

extension MeetingStore {
    /// Moments are kept out of transcript.json: that file is rewritten on every partial transcript event, and a long
    /// meeting's screen text would multiply the cost of each write.
    public func loadScreenMoments(_ id: String) -> [ScreenMoment] {
        guard let url = try? directory(id).appendingPathComponent(ScreenFiles.moments),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ScreenMoment].self, from: data)) ?? []
    }

    public func saveScreenMoments(_ moments: [ScreenMoment], id: String) throws {
        ScreenFiles.mutationLock.lock(); defer { ScreenFiles.mutationLock.unlock() }
        let meeting = try load(id)
        guard meeting.retention != "purged", meeting.retention != "purging", meeting.screen?.state != "deleted" else { return }
        let folder = try directory(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(ScreenFiles.moments)
        try JSONEncoder().encode(moments).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Removes a meeting's screen recording, thumbnails and screen text, keeping its audio and transcript. With
    /// `trash`, files go to the Trash (recoverable in Finder, like deleting a recording); otherwise they are removed.
    /// The next index pass drops the meeting's screen moments from search.
    @discardableResult
    public func deleteScreenCapture(_ id: String, trash: Bool = true) throws -> Meeting {
        ScreenFiles.mutationLock.lock(); defer { ScreenFiles.mutationLock.unlock() }
        var meeting = try load(id)
        let folder = try directory(id)
        for name in Set([ScreenFiles.video, ScreenFiles.thumbnails, ScreenFiles.moments] + (meeting.recordingSessions ?? []).compactMap { $0.screen?.file }) {
            let url = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if trash { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            else { try FileManager.default.removeItem(at: url) }
        }
        var info = meeting.screen ?? ScreenCaptureInfo(state: "deleted")
        info.file = nil; info.state = "deleted"; info.momentCount = 0; info.deletedAt = Date(); info.failure = nil
        meeting.screen = info
        for i in (meeting.recordingSessions ?? []).indices { meeting.recordingSessions?[i].screen = nil }
        try save(meeting)
        return meeting
    }
}

/// Apps whose windows are never recorded or read. Their windows are excluded from the capture itself, and a frame is
/// never embedded, OCR'd or indexed while one of them is frontmost. Users can edit the list (UserDefaults "screenDenyList").
public enum ScreenPrivacy {
    public static let defaultDeniedBundleIDs: [String] = [
        "com.1password.1password",          // 1Password 8
        "com.agilebits.onepassword7",       // 1Password 7
        "com.apple.keychainaccess",         // Keychain Access
        "com.apple.Passwords",              // Passwords (macOS 15+)
        "com.apple.MobileSMS",              // Messages
        "com.bitwarden.desktop",            // Bitwarden
        "com.lastpass.LastPass",            // LastPass
        "com.dashlane.dashlanephonefinal",  // Dashlane
    ]

    public static func isDenied(_ bundleID: String?, list: [String] = defaultDeniedBundleIDs) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return list.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }
}

// MARK: Live context

/// What is on screen right now, for live answers.
public struct ScreenSnapshot: Sendable, Equatable {
    public var text: String
    public var capturedAt: Date
    public var app: String?
    public var window: String?
    public var meetingID: String?
    /// Meeting seconds of the frame the text came from.
    public var meetingSeconds: Double?
    public init(text: String, capturedAt: Date, app: String? = nil, window: String? = nil, meetingID: String? = nil,
                meetingSeconds: Double? = nil) {
        self.text = text; self.capturedAt = capturedAt; self.app = app; self.window = window
        self.meetingID = meetingID; self.meetingSeconds = meetingSeconds
    }
}

/// The latest screen text, in process. The screen recorder publishes each OCR'd keyframe; a live answer reads it:
///
///     if let now = ScreenContext.current(maxAge: 30) { prompt += "On screen (\(now.app ?? "")): \(now.text)" }
///
/// It is cleared when screen capture stops, pauses, or a private app comes to the front, so stale text from before is
/// never presented as "now".
public final class ScreenContext: @unchecked Sendable {
    public static let shared = ScreenContext()
    private let lock = NSLock()
    private var latest: ScreenSnapshot?
    private var observers: [UUID: @Sendable (ScreenSnapshot?) -> Void] = [:]
    public init() {}

    /// The newest snapshot, or nil when there is none or it is older than `maxAge` seconds.
    public static func current(maxAge: TimeInterval? = nil, now: Date = Date()) -> ScreenSnapshot? {
        shared.current(maxAge: maxAge, now: now)
    }

    public func current(maxAge: TimeInterval? = nil, now: Date = Date()) -> ScreenSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let latest else { return nil }
        if let maxAge, now.timeIntervalSince(latest.capturedAt) > maxAge { return nil }
        return latest
    }

    public func publish(_ snapshot: ScreenSnapshot?) {
        lock.lock(); latest = snapshot; let callbacks = Array(observers.values); lock.unlock()
        callbacks.forEach { $0(snapshot) }
    }

    public func clear() { publish(nil) }

    /// Called (on the recorder's queue) with every new snapshot, and nil when cleared. Keep the token to stop.
    @discardableResult
    public func observe(_ body: @escaping @Sendable (ScreenSnapshot?) -> Void) -> UUID {
        let id = UUID()
        lock.lock(); observers[id] = body; lock.unlock()
        return id
    }

    public func removeObserver(_ id: UUID) { lock.lock(); observers.removeValue(forKey: id); lock.unlock() }
}

/// Builds the context a live answer sees: the last stretch of transcript plus what was on screen meanwhile, both
/// labeled with meeting time so a model can say "the slide at 12:40".
public enum LiveContext {
    public static func compose(meeting: Meeting, screen: [ScreenMoment], now: Double, window: Double = 120,
                               current: ScreenSnapshot? = nil, maxScreenCharacters: Int = 2_000) -> String {
        var out: [String] = []
        let since = max(0, now - window)
        let lines = meeting.orderedSegments.filter { $0.end >= since }
            .map { "[\(clock($0.start))] \(meeting.speakerName(for: $0)): \($0.text)" }
        if !lines.isEmpty { out.append("Transcript (last \(Int(window)) s):\n" + lines.joined(separator: "\n")) }

        var budget = maxScreenCharacters
        var screenLines: [String] = []
        if let current, !current.text.isEmpty {
            let label = [current.app, current.window].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
            let text = String(current.text.prefix(budget))
            budget -= text.count
            screenLines.append("Now\(label.isEmpty ? "" : " (\(label))"):\n\(text)")
        }
        for moment in screen.filter({ $0.end >= since }).sorted(by: { $0.start > $1.start }) where budget > 0 {
            if let current, moment.text == current.text { continue }
            let text = String(moment.text.prefix(budget))
            budget -= text.count
            screenLines.append("[\(clock(moment.start))–\(clock(moment.end))]\(moment.context.map { " \($0)" } ?? ""):\n\(text)")
        }
        if !screenLines.isEmpty { out.append("On screen (newest first; OCR, may contain errors):\n" + screenLines.joined(separator: "\n\n")) }
        return out.joined(separator: "\n\n")
    }

    static func clock(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%02d:%02d", value / 60, value % 60)
    }
}
