import Foundation

/// A day as the popover shows it: meetings and stretches of one app, newest first, with a strip of the
/// day above them. Built from what the day's journal already keeps (`AppSpan`) and the meetings that
/// began that day. Times are seconds from the day's local midnight.
public struct DayTimeline: Equatable, Sendable {
    /// A meeting that began on this day.
    public struct MeetingRef: Equatable, Sendable {
        public var id: String
        public var title: String
        public var start: Double
        /// Nil while it is still being recorded.
        public var end: Double?
        public init(id: String, title: String, start: Double, end: Double?) {
            self.id = id; self.title = title; self.start = start; self.end = end
        }
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable {
            case app(bundleID: String?)
            case meeting(id: String)
        }
        public var id: String
        public var kind: Kind
        /// The app's name, or the meeting's title.
        public var title: String
        public var start: Double
        public var end: Double
        /// How long the app was in front, or how long the meeting lasted.
        public var seconds: Double
        /// Window titles seen in the app, or on screen during the meeting, in order of first appearance.
        public var windows: [String]
        /// Still going.
        public var current: Bool

        public var isMeeting: Bool { if case .meeting = kind { true } else { false } }
    }

    /// One stretch on the strip.
    public struct Segment: Equatable, Sendable {
        public var start: Double
        public var end: Double
        /// The app (`AppTotal`-style key: bundle identifier, or its name when it has none).
        public var key: String
    }

    public struct Total: Equatable, Sendable, Identifiable {
        public var key: String
        public var app: String
        public var seconds: Double
        public var id: String { key }
    }

    public var rows: [Row] = []
    public var segments: [Segment] = []
    /// When meetings were being recorded.
    public var meetings: [Segment] = []
    /// Apps by time in front, longest first.
    public var totals: [Total] = []
    /// The strip's span: from the hour the day's first activity began in, to now.
    public var from = 0.0
    public var to = 0.0

    public var isEmpty: Bool { rows.isEmpty }
    /// Time with a readable app in front.
    public var seconds: Double { totals.reduce(0) { $0 + $1.seconds } }

    public init() {}

    /// - Parameters:
    ///   - brief: an app in front for less than this is passing through. It counts towards the totals and the
    ///     strip, and gets no row of its own (nor does it split the row of the app around it).
    ///   - join: two stretches of the same app no further apart than this, with nothing but brief visits
    ///     between them, are one row.
    ///   - currentWithin: a stretch that ended this recently is still going (the journal writes an open
    ///     stretch only every half minute).
    public static func build(spans: [AppSpan], meetings: [MeetingRef], now: Double, brief: Double = 30, join: Double = 300,
                             currentWithin: Double = 75, maximumWindows: Int = 8) -> DayTimeline {
        var out = DayTimeline()
        let spans = spans.filter { $0.end >= $0.start }.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        func key(_ span: AppSpan) -> String { span.bundleID ?? span.app }

        var totals: [String: Total] = [:]
        for span in spans {
            totals[key(span), default: Total(key: key(span), app: span.app, seconds: 0)].seconds += span.seconds
            if let last = out.segments.last, last.key == key(span), span.start - last.end <= 5 {
                out.segments[out.segments.count - 1].end = max(last.end, span.end)
            } else {
                out.segments.append(Segment(start: span.start, end: span.end, key: key(span)))
            }
        }
        out.totals = totals.values.sorted { $0.seconds == $1.seconds ? $0.app < $1.app : $0.seconds > $1.seconds }

        // Stretches of one app, outside meetings.
        var rows: [Row] = []
        let outside = spans.filter { $0.meetingID == nil }
        for (index, span) in outside.enumerated() {
            let latest = index == outside.count - 1 && now - span.end <= currentWithin
            guard span.seconds >= brief || latest else { continue }
            if let last = rows.last, case .app(let bundleID) = last.kind, (bundleID ?? last.title) == key(span), span.start - last.end <= join,
               // A meeting between them is its own row, and belongs between them.
               !meetings.contains(where: { $0.start >= last.end - 1 && $0.start <= span.start + 1 }) {
                var merged = last
                merged.end = max(last.end, span.end); merged.seconds += span.seconds; merged.current = latest
                for window in span.windows where !merged.windows.contains(window) && merged.windows.count < maximumWindows { merged.windows.append(window) }
                rows[rows.count - 1] = merged
            } else {
                rows.append(Row(id: span.id, kind: .app(bundleID: span.bundleID), title: span.app, start: span.start, end: span.end,
                                seconds: span.seconds, windows: Array(span.windows.prefix(maximumWindows)), current: latest))
            }
        }

        for meeting in meetings {
            let start = max(0, meeting.start), end = max(start, meeting.end ?? now)
            var windows: [String] = []
            for span in spans where span.meetingID == meeting.id {
                for window in span.windows where !windows.contains(window) && windows.count < maximumWindows { windows.append(window) }
            }
            rows.append(Row(id: "meeting:" + meeting.id, kind: .meeting(id: meeting.id), title: meeting.title, start: start, end: end,
                            seconds: end - start, windows: windows, current: meeting.end == nil))
            out.meetings.append(Segment(start: start, end: end, key: meeting.id))
        }
        out.rows = rows.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start > $1.start }

        let first = min(spans.first?.start ?? now, meetings.map { max(0, $0.start) }.min() ?? now)
        out.to = max(now, first + 60)
        out.from = min((first / 3600).rounded(.down) * 3600, out.to - 3600)
        return out
    }

    /// "24 min", "1h 18m", "45 sec": how long, in the fewest words.
    public static func length(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        if value < 60 { return "\(value) sec" }
        if value < 3600 { return "\(value / 60) min" }
        return value % 3600 < 60 ? "\(value / 3600)h" : "\(value / 3600)h \(String(format: "%02d", value % 3600 / 60))m"
    }
}
