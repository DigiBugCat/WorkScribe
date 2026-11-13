import Foundation

// Screen reading outside meetings: one journal per calendar day, organised by application.
//
// A day holds two things. `moments` are stretches of one window and the text it showed, exactly as
// in a meeting. `usage` is which app was in front and when, with its window titles and no text.
// What is read while a meeting is being recorded belongs to that meeting and fades with it; the
// day keeps only the usage span for that time. So every reading has exactly one home (`ScreenRoute`).

/// A stretch of time with one app in front.
public struct AppSpan: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var bundleID: String?
    public var app: String
    /// The kind of app in plain words ("Browser", "Developer tools"), when known.
    public var category: String?
    /// Seconds into the day.
    public var start: Double
    public var end: Double
    /// Window titles seen in this span, in order of first appearance.
    public var windows: [String]
    /// The meeting being recorded during this span, when there was one.
    public var meetingID: String?

    public init(id: String = UUID().uuidString, bundleID: String?, app: String, category: String? = nil, start: Double, end: Double,
                windows: [String] = [], meetingID: String? = nil) {
        self.id = id; self.bundleID = bundleID; self.app = app; self.category = category; self.start = start; self.end = end
        self.windows = windows; self.meetingID = meetingID
    }
    public var seconds: Double { max(0, end - start) }
}

/// Turns "this app is in front, now" notes into spans.
public struct AppUsageBuilder: Sendable {
    /// Notes further apart than this are two spans (the Mac slept, reading was paused, a private app was in front).
    public var gap = 5.0
    /// A span shorter than this is passing through (Command-Tab over an app), not use.
    public var minimumSeconds = 1.0
    public var maximumWindows = 24
    public private(set) var closed: [AppSpan]
    public private(set) var open: AppSpan?

    public init(earlier: [AppSpan] = []) { closed = earlier }

    public var all: [AppSpan] { closed + (open.map { [$0] } ?? []) }

    /// `app` is in front at `time`. Returns true when a span started or a new window title was seen (worth saving).
    @discardableResult
    public mutating func note(app: String?, bundleID: String?, category: String? = nil, window: String? = nil,
                              meetingID: String? = nil, at time: Double) -> Bool {
        let name = app?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? bundleID ?? "Unknown app"
        let title = window?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if var current = open, current.meetingID == meetingID, time - current.end <= gap, time >= current.start,
           bundleID != nil ? current.bundleID == bundleID : (current.bundleID == nil && current.app == name) {
            current.end = max(current.end, time)
            var changed = false
            if let title, !current.windows.contains(title), current.windows.count < maximumWindows {
                current.windows.append(title); changed = true
            }
            open = current
            return changed
        }
        close()
        open = AppSpan(bundleID: bundleID, app: name, category: category, start: time, end: time,
                       windows: title.map { [$0] } ?? [], meetingID: meetingID)
        return true
    }

    /// The app is no longer in front (or nothing may be noted): the open span ends where it was last seen.
    public mutating func close() {
        guard let current = open else { return }
        open = nil
        if current.seconds >= minimumSeconds { closed.append(current) }
    }
}

/// What kind of app this is, in plain words.
public enum AppCategory {
    /// A few kinds macOS has no category for, by bundle identifier; otherwise the category the app declares
    /// for itself (`LSApplicationCategoryType` in its Info.plist).
    public static func name(bundleID: String?, declared: String?) -> String? {
        if let bundleID = bundleID?.lowercased() {
            for (kind, ids) in known where ids.contains(where: { bundleID == $0 || bundleID.hasPrefix($0 + ".") }) { return kind }
        }
        guard var value = declared?.lowercased(), !value.isEmpty else { return nil }
        if value.hasPrefix("public.app-category.") { value.removeFirst("public.app-category.".count) }
        if value.hasSuffix("-games") || value == "games" { return "Games" }
        if let plain = plain[value] { return plain }
        let words = value.replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    static let plain: [String: String] = [
        "developer-tools": "Developer tools", "productivity": "Productivity", "business": "Business",
        "social-networking": "Social", "graphics-design": "Design", "utilities": "Utilities", "finance": "Finance",
        "education": "Education", "entertainment": "Entertainment", "music": "Music", "video": "Video",
        "photography": "Photography", "news": "News", "reference": "Reference", "lifestyle": "Lifestyle",
        "medical": "Medical", "travel": "Travel", "weather": "Weather", "healthcare-fitness": "Health",
        "sports": "Sports", "navigation": "Navigation",
    ]

    static let known: [(String, [String])] = [
        ("Browser", ["com.apple.safari", "com.apple.safaritechnologypreview", "com.google.chrome", "org.mozilla.firefox",
                     "company.thebrowser.browser", "company.thebrowser.dia", "com.microsoft.edgemac", "com.brave.browser",
                     "com.vivaldi.vivaldi", "com.operasoftware.opera", "com.kagi.kagimacos", "app.zen-browser.zen",
                     "org.chromium.chromium", "com.duckduckgo.macos.browser"]),
        ("Calls", ["us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2", "com.cisco.webexmeetingsapp",
                   "com.apple.facetime", "com.google.meet", "com.webex.meetingmanager"]),
        ("Chat", ["com.tinyspeck.slackmacgap", "com.hnc.discord", "ru.keepcoder.telegram", "net.whatsapp.whatsapp",
                  "org.whispersystems.signal-desktop", "com.apple.mobilesms"]),
        ("Mail", ["com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail-mac", "com.superhuman.electron"]),
        ("Terminal", ["com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable", "com.mitchellh.ghostty",
                      "net.kovidgoyal.kitty", "org.alacritty", "co.zeit.hyper", "com.github.wez.wezterm"]),
        ("Notes", ["md.obsidian", "com.apple.notes", "notion.id", "com.logseq.logseq", "net.shinyfrog.bear"]),
    ]
}

/// One calendar day of screen reading.
public struct ScreenDay: Codable, Equatable, Sendable {
    /// "2026-11-11", in the calendar the Mac was in when the day began.
    public var day: String
    /// Local midnight. Moment and span times are seconds from here.
    public var start: Date
    public var moments: [ScreenMoment]
    public var usage: [AppSpan]

    public init(day: String, start: Date, moments: [ScreenMoment] = [], usage: [AppSpan] = []) {
        self.day = day; self.start = start; self.moments = moments; self.usage = usage
    }

    public var isEmpty: Bool { moments.isEmpty && usage.isEmpty }

    /// How long each app was in front, longest first, with what was open in it.
    public func byApp() -> [AppTotal] {
        var totals: [String: AppTotal] = [:]
        var order: [String] = []
        for span in usage {
            let key = span.bundleID ?? span.app
            if totals[key] == nil { totals[key] = AppTotal(bundleID: span.bundleID, app: span.app, category: span.category); order.append(key) }
            totals[key]!.seconds += span.seconds
            totals[key]!.spans += 1
            for window in span.windows where !totals[key]!.windows.contains(window) && totals[key]!.windows.count < 12 {
                totals[key]!.windows.append(window)
            }
        }
        for moment in moments {
            let key = moment.bundleID ?? moment.app ?? ""
            totals[key]?.moments += 1
        }
        return order.compactMap { totals[$0] }.sorted { $0.seconds == $1.seconds ? $0.app < $1.app : $0.seconds > $1.seconds }
    }

    /// Moments of one app, named by bundle identifier or by (part of) its name, case-insensitively.
    public func moments(app: String) -> [ScreenMoment] {
        moments.filter { Self.matches(app, bundleID: $0.bundleID, name: $0.app) }
    }
    public func usage(app: String) -> [AppSpan] {
        usage.filter { Self.matches(app, bundleID: $0.bundleID, name: $0.app) }
    }
    /// Drops everything read from one app, and the fact that it was in front.
    public mutating func forget(bundleID: String) {
        moments.removeAll { $0.bundleID?.caseInsensitiveCompare(bundleID) == .orderedSame }
        usage.removeAll { $0.bundleID?.caseInsensitiveCompare(bundleID) == .orderedSame }
    }
    static func matches(_ wanted: String, bundleID: String?, name: String?) -> Bool {
        let wanted = wanted.lowercased()
        guard !wanted.isEmpty else { return true }
        if bundleID?.lowercased() == wanted { return true }
        return name?.lowercased().contains(wanted) ?? false
    }
}

public struct AppTotal: Equatable, Sendable {
    public var bundleID: String?
    public var app: String
    public var category: String?
    public var seconds = 0.0
    public var spans = 0
    public var moments = 0
    public var windows: [String] = []
}

/// Where the day journals live: one file per day, readable only by the user.
///
/// A day is an append-only log, one JSON record per line, folded on load (the last record for a moment
/// or a span wins). Reading goes on all day and a day's text runs to megabytes; rewriting the whole
/// day each time a window changes would write gigabytes. `save` rewrites a day compactly.
public struct ScreenDayStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    /// Next to the meetings, like the retention journal: one data folder, and a test library has its own.
    public init(meetings: MeetingStore) { root = meetings.root.appendingPathComponent(".screen", isDirectory: true) }

    /// The day `date` falls on, and its midnight.
    public static func day(_ date: Date, calendar: Calendar = .current) -> (id: String, start: Date) {
        let start = calendar.startOfDay(for: date)
        let parts = calendar.dateComponents([.year, .month, .day], from: start)
        return (String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0), start)
    }
    public static func isDay(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0].count == 4 && parts[1].count == 2 && parts[2].count == 2
            && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    /// One line of a day's log.
    public struct Record: Codable, Sendable {
        /// "day" (header) · "m" (a moment, without its vector) · "v" (a moment's picture vector) · "u" (an app span)
        public var t: String
        public var day: String?
        public var start: Date?
        public var moment: ScreenMoment?
        public var span: AppSpan?
        public var id: String?
        public var model: String?
        public var at: Double?
        /// Little-endian 32-bit floats, base64.
        public var vector: String?

        public static func moment(_ moment: ScreenMoment) -> Record {
            var bare = moment; bare.embedding = nil
            return Record(t: "m", moment: bare)
        }
        public static func vector(of moment: ScreenMoment) -> Record? {
            guard let vector = moment.embedding else { return nil }
            let data = vector.withUnsafeBufferPointer { Data(buffer: $0) }
            return Record(t: "v", id: moment.id, model: moment.embeddingModelID, at: moment.representativeTime, vector: data.base64EncodedString())
        }
        public static func span(_ span: AppSpan) -> Record { Record(t: "u", span: span) }
    }

    func url(_ day: String) -> URL { root.appendingPathComponent(day + ".jsonl") }

    private static func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
    private static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    public func load(_ day: String) -> ScreenDay? {
        guard Self.isDay(day), let data = try? Data(contentsOf: url(day)) else { return nil }
        let decoder = Self.decoder()
        var start: Date?
        var moments: [String: ScreenMoment] = [:], spans: [String: AppSpan] = [:]
        var vectors: [String: (model: String?, at: Double?, vector: [Float])] = [:]
        // A line cut short by a crash does not decode; the rest of the day still does.
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let record = try? decoder.decode(Record.self, from: line) else { continue }
            switch record.t {
            case "day": start = record.start ?? start
            case "m": if let moment = record.moment { moments[moment.id] = moment }
            case "u": if let span = record.span { spans[span.id] = span }
            case "v":
                guard let id = record.id, let raw = record.vector.flatMap({ Data(base64Encoded: $0) }), raw.count % 4 == 0 else { continue }
                var floats = [Float](repeating: 0, count: raw.count / 4)
                _ = floats.withUnsafeMutableBytes { raw.copyBytes(to: $0) }
                vectors[id] = (record.model, record.at, floats)
            default: continue
            }
        }
        guard let start else { return nil }
        let withVectors = moments.values.map { moment -> ScreenMoment in
            var moment = moment
            if let vector = vectors[moment.id] {
                moment.embedding = vector.vector; moment.embeddingModelID = vector.model; moment.representativeTime = vector.at
            }
            return moment
        }
        return ScreenDay(day: day, start: start,
                         moments: withVectors.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start },
                         usage: spans.values.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start })
    }

    private func lines(_ records: [Record]) throws -> Data {
        let encoder = Self.encoder()
        var out = Data()
        for record in records { out.append(try encoder.encode(record)); out.append(UInt8(ascii: "\n")) }
        return out
    }

    /// Adds records to a day's log, starting it (with its header) when it does not exist.
    public func append(day: String, start: Date, _ records: [Record]) throws {
        guard Self.isDay(day), !records.isEmpty else { return }
        Self.lock.lock(); defer { Self.lock.unlock() }
        let file = url(day)
        if !FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try lines([Record(t: "day", day: day, start: start)] + records).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: lines(records))
    }

    /// Rewrites a day compactly: one record per moment, vector and span.
    public func save(_ day: ScreenDay) throws {
        guard Self.isDay(day.day) else { throw CocoaError(.fileWriteInvalidFileName) }
        Self.lock.lock(); defer { Self.lock.unlock() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let records = [Record(t: "day", day: day.day, start: day.start)] + day.moments.map(Record.moment)
            + day.moments.compactMap(Record.vector) + day.usage.map(Record.span)
        let file = url(day.day)
        try lines(records).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// The days there is a journal for, newest first.
    public func days() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap { name -> String? in
            guard name.hasSuffix(".jsonl") else { return nil }
            let day = String(name.dropLast(6))
            return Self.isDay(day) ? day : nil
        }.sorted(by: >)
    }

    public func modified(_ day: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url(day).path))?[.modificationDate] as? Date
    }
    public func bytes(_ day: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url(day).path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    public func delete(_ day: String) throws {
        guard Self.isDay(day) else { return }
        Self.lock.lock(); defer { Self.lock.unlock() }
        let file = url(day)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    /// Removes journals older than the last `keeping` days (today counts as one). Returns the days removed.
    /// `keeping` of zero or less keeps everything.
    @discardableResult
    public func prune(keeping: Int, now: Date = Date(), calendar: Calendar = .current) throws -> [String] {
        guard keeping > 0, let oldest = calendar.date(byAdding: .day, value: -(keeping - 1), to: calendar.startOfDay(for: now)) else { return [] }
        let cutoff = Self.day(oldest, calendar: calendar).id
        let gone = days().filter { $0 < cutoff }
        for day in gone { try delete(day) }
        return gone
    }

    /// Serializes writes of a journal with its deletion.
    static let lock = NSRecursiveLock()
}

/// Today's journal while it is being written: moments and app spans, rolled over at midnight.
///
/// Not thread-safe; the watcher owns one on its queue. What has ended is written at once. What is still
/// open (the window in front, the app in front) is written when it starts and then at most every
/// `openInterval`, so a crash loses seconds, not the day.
public struct ScreenDayJournal {
    public let store: ScreenDayStore
    public var calendar: Calendar
    public var openInterval = 30.0
    /// A log longer than this many bytes is folded into its compact form now and then.
    public var compactAbove = 6_000_000

    public private(set) var day: String
    private var start: Date
    private var earlier: [ScreenMoment] = []
    private var earlierUsage: [AppSpan] = []
    private var builder = ScreenMomentBuilder()
    private var usage = AppUsageBuilder()
    private var written: [String: String] = [:]
    private var vectorsWritten = Set<String>()
    private var lastOpenWrite = Date.distantPast
    private var appended = 0
    /// How many ended moments and spans of this run are already on disk.
    private var momentsEnded = 0, spansEnded = 0

    public init(store: ScreenDayStore, now: Date = Date(), calendar: Calendar = .current) {
        self.store = store; self.calendar = calendar
        let today = ScreenDayStore.day(now, calendar: calendar)
        day = today.id; start = today.start
        open()
    }

    private mutating func open() {
        builder = ScreenMomentBuilder(); usage = AppUsageBuilder()
        written = [:]; vectorsWritten = []; lastOpenWrite = .distantPast; appended = 0; momentsEnded = 0; spansEnded = 0
        let existing = store.load(day)
        earlier = existing?.moments ?? []; earlierUsage = existing?.usage ?? []
        // Tidy a log left long by an earlier run.
        if let existing, store.bytes(day) > compactAbove { try? store.save(existing) }
    }

    public func seconds(_ date: Date) -> Double { date.timeIntervalSince(start) }

    /// The day as it stands, including what is still open.
    public var current: ScreenDay {
        ScreenDay(day: day, start: start, moments: earlier + builder.all, usage: earlierUsage + usage.all)
    }
    public var momentCount: Int { earlier.count + builder.all.count }

    /// A new day began: what was open ends at midnight and the journal moves on.
    private mutating func roll(to date: Date) {
        let today = ScreenDayStore.day(date, calendar: calendar)
        guard today.id != day else { return }
        builder.close(at: min(seconds(date), seconds(today.start)))
        usage.close()
        _ = try? flush(now: date, force: true)
        day = today.id; start = today.start
        open()
    }

    /// A permitted reading of the window in front.
    public mutating func keep(_ observation: ScreenObservation, at date: Date) {
        roll(to: date)
        var observation = observation
        observation.time = seconds(date)
        builder.add(observation)
    }

    /// The current stretch of screen ended (another app, a private window, pause, lock, stop).
    public mutating func endMoment(at date: Date) {
        roll(to: date)
        builder.close(at: seconds(date))
    }

    /// `app` is in front and may be read.
    public mutating func note(app: String?, bundleID: String?, category: String?, window: String?, meetingID: String?, at date: Date) {
        roll(to: date)
        usage.note(app: app, bundleID: bundleID, category: category, window: window, meetingID: meetingID, at: seconds(date))
    }

    /// Nothing may be noted now: the open span ends where it was last seen.
    public mutating func endUsage() { usage.close() }

    public struct Flushed: Equatable, Sendable {
        public var wrote = false
        /// Moments that ended and are now on disk: worth telling the index about.
        public var ended = 0
    }

    /// Writes what changed. Returns what was written.
    ///
    /// Called every second, all day, so it must not look at the whole day each time: what has ended never
    /// changes again and is written exactly once; only the one open moment and the one open span are compared.
    @discardableResult
    public mutating func flush(now: Date = Date(), force: Bool = false) throws -> Flushed {
        var records: [ScreenDayStore.Record] = []
        var result = Flushed()
        let openDue = force || now.timeIntervalSince(lastOpenWrite) >= openInterval
        var wroteOpen = false

        for moment in builder.closed.dropFirst(momentsEnded) {
            records.append(.moment(moment)); result.ended += 1
            if !vectorsWritten.contains(moment.id), let record = ScreenDayStore.Record.vector(of: moment) { records.append(record) }
            vectorsWritten.remove(moment.id); written[moment.id] = nil
        }
        if let moment = builder.open {
            let mark = "\(Int(moment.end))|\(moment.text.count)|\(moment.window ?? "")|\(moment.url ?? "")"
            // Written when it first appears, then when due.
            if written[moment.id] != mark, written[moment.id] == nil || openDue {
                records.append(.moment(moment)); written[moment.id] = mark; wroteOpen = true
            }
            if moment.embedding != nil, !vectorsWritten.contains(moment.id), let record = ScreenDayStore.Record.vector(of: moment) {
                records.append(record); vectorsWritten.insert(moment.id)
            }
        }
        for span in usage.closed.dropFirst(spansEnded) { records.append(.span(span)); written["u" + span.id] = nil }
        if let span = usage.open {
            let key = "u" + span.id, mark = "\(Int(span.end))|\(span.windows.count)"
            if written[key] != mark, written[key] == nil || openDue {
                records.append(.span(span)); written[key] = mark; wroteOpen = true
            }
        }

        guard !records.isEmpty else { return result }
        try store.append(day: day, start: start, records)
        momentsEnded = builder.closed.count; spansEnded = usage.closed.count
        if wroteOpen { lastOpenWrite = now }
        result.wrote = true
        appended += records.count
        // Many updates of open moments make a long log; fold it now and then.
        if appended > 2_000, store.bytes(day) > compactAbove { try? store.save(current); appended = 0 }
        return result
    }

    /// Forgets what was read from one app today, on disk and in memory.
    public mutating func forget(bundleID: String, now: Date = Date()) throws {
        roll(to: now)
        builder.close(at: seconds(now)); usage.close()
        _ = try flush(now: now, force: true)
        if var whole = store.load(day) { whole.forget(bundleID: bundleID); try store.save(whole) }
        open()
    }

    /// Forgets today: the file and everything in memory.
    public mutating func clear() throws {
        try store.delete(day)
        earlier = []; earlierUsage = []
        builder = ScreenMomentBuilder(); usage = AppUsageBuilder()
        written = [:]; vectorsWritten = []; lastOpenWrite = .distantPast; appended = 0; momentsEnded = 0; spansEnded = 0
    }
}

/// Where a reading belongs. Each one has exactly one home, decided by when its window was read: the
/// meeting being recorded at that moment, or else the day.
public struct ScreenRoute: Sendable, Equatable {
    public enum Home: Equatable, Sendable { case meeting(String), day, nowhere }
    /// Whether readings outside meetings are kept at all.
    public var keepsDay: Bool
    private var meeting: String?
    private var since = 0.0
    private var lastMeetingEnd = -Double.infinity

    public init(keepsDay: Bool) { self.keepsDay = keepsDay }

    public var currentMeeting: String? { meeting }

    public mutating func begin(meeting id: String, at time: Double) { meeting = id; since = time }
    public mutating func endMeeting(at time: Double) {
        guard meeting != nil else { return }
        meeting = nil; lastMeetingEnd = max(lastMeetingEnd, time)
    }

    public func home(at time: Double) -> Home {
        if let meeting, time >= since { return .meeting(meeting) }
        // Read while a meeting that has since ended was recording: that meeting's timeline is closed, and
        // the day must not pick up what was the meeting's.
        if time < lastMeetingEnd { return .nowhere }
        return keepsDay ? .day : .nowhere
    }
}

/// A day's screen reading as search passages: its own source in the index, timed in seconds into the day.
public enum ScreenDaySource {
    public static let prefix = "screen-day:"
    public static func ref(_ day: String) -> String { prefix + day }
    public static func day(ref: String) -> String? {
        guard ref.hasPrefix(prefix) else { return nil }
        let day = String(ref.dropFirst(prefix.count))
        return ScreenDayStore.isDay(day) ? day : nil
    }

    /// "Screen · Wed 11 Nov 2026"
    public static func title(_ day: ScreenDay, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE d MMM yyyy"
        return "Screen · " + formatter.string(from: day.start)
    }

    public static func passages(_ day: ScreenDay) -> [Passage] {
        let source = SourceID(.screen, ref(day.day))
        return day.moments.sorted { $0.start < $1.start }.flatMap { moment -> [Passage] in
            guard moment.embedding != nil || ScreenMomentBuilder.words(moment.text).count >= 3 else { return [] }
            var result: [Passage] = []
            if let vector = moment.embedding {
                result.append(Passage(text: moment.context ?? "Visual scene", source: source, anchor: moment.id + ":image",
                                      start: moment.start, end: moment.end, kind: .screen, modality: .image, track: "screen",
                                      window: moment.context, vector: vector))
            }
            if !moment.text.isEmpty {
                result.append(Passage(text: moment.text, source: source, anchor: moment.id + ":ocr", context: moment.context,
                                      start: moment.start, end: moment.end, kind: .screen, track: "screen", window: moment.context))
            }
            return result
        }
    }

    public static func fingerprint(_ day: ScreenDay) -> String {
        // Cheap on purpose: this runs over every day at each sync. A moment's vector is fixed by which
        // moment it is and when the picture was taken, so the numbers themselves need not be hashed.
        var hash = StableHash()
        for moment in day.moments.sorted(by: { $0.start < $1.start }) {
            hash.add(moment.id); hash.add(moment.text); hash.add(moment.context ?? "")
            hash.add(String(format: "%.0f-%.0f", moment.start, moment.end))
            hash.add(moment.embedding == nil ? "" : (moment.embeddingModelID ?? "") + String(describing: moment.representativeTime))
        }
        return "screen-day1:\(day.moments.count):" + hash.hex
    }

    public static func revision(_ day: ScreenDay, calendar: Calendar = .current) -> SourceRevision {
        var revision = SourceRevision(source: SourceID(.screen, ref(day.day)), passages: passages(day), title: title(day, calendar: calendar),
                                      startedAt: day.start, fingerprint: fingerprint(day))
        revision.metadata = ["day": day.day]
        return revision
    }
}

/// Keeps the index in step with the day journals: a changed day is re-chunked (unchanged moments keep their
/// rows and vectors), a day whose journal is gone leaves the index.
public struct ScreenDayIndexer: Sendable {
    public let index: SearchIndex
    public let embedder: (any Embedder)?
    public let gate: @Sendable () async -> Void

    public init(index: SearchIndex, embedder: (any Embedder)?, gate: @escaping @Sendable () async -> Void = {}) {
        self.index = index; self.embedder = embedder; self.gate = gate
    }

    public func sync(store: ScreenDayStore) async throws -> IndexReport {
        if let embedder { try index.adopt(modelID: embedder.modelID) }
        var report = IndexReport()
        let days = store.days()
        let wanted = Set(days.map(ScreenDaySource.ref))
        for source in try index.sources(kind: .screen) where !wanted.contains(source.ref) {
            try index.remove(ref: source.ref); report.removed += 1
        }
        for id in days {
            try Task.checkCancellation()
            guard let day = store.load(id) else { report.failed += 1; continue }
            do {
                switch try await index(day) {
                case .indexed: report.indexed += 1
                case .unchanged: report.unchanged += 1
                case .refreshed: report.refreshed += 1
                }
            } catch is CancellationError { throw CancellationError() }
            catch { report.failed += 1 }
        }
        return report
    }

    @discardableResult
    public func index(_ day: ScreenDay) async throws -> MeetingIndexer.Outcome {
        if let embedder { try index.adopt(modelID: embedder.modelID) }
        // Picture vectors are only usable in the index's own space; one from another model is left out.
        let space = embedder?.modelID ?? index.vectorModel ?? day.moments.last(where: { $0.embedding != nil })?.embeddingModelID
        var compatible = day
        compatible.moments = day.moments.map { moment in
            var moment = moment
            if moment.embeddingModelID != space || moment.embeddingModelID == nil { moment.embedding = nil }
            return moment
        }
        if index.vectorModel == nil, let space { try index.adopt(modelID: space) }
        let revision = ScreenDaySource.revision(compatible)
        if let existing = try index.source(ref: revision.source.ref), existing.fingerprint == revision.fingerprint,
           embedder == nil || existing.modelID == embedder?.modelID {
            return .unchanged
        }
        _ = try index.apply(revision)
        if let embedder { try await index.embedMissing(revision.source, using: embedder, gate: gate) }
        return .indexed
    }
}
