import CoreGraphics
import Foundation

/// A frame reduced to a small grayscale grid: cheap to compare, enough to tell a new slide from a blinking caret.
public struct FrameSignature: Sendable, Equatable {
    public static let width = 96
    public static let height = 54
    /// Row-major, `width` × `height`, 0 (black) … 255 (white).
    public let luminance: [UInt8]

    public init(luminance: [UInt8]) {
        precondition(luminance.count == Self.width * Self.height, "luminance must be \(Self.width)×\(Self.height)")
        self.luminance = luminance
    }

    /// Draws `image` into the grid (area-averaged by Core Graphics). Nil if it can't be drawn.
    public init?(image: CGImage) {
        var pixels = [UInt8](repeating: 0, count: Self.width * Self.height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: Self.width, height: Self.height, bitsPerComponent: 8,
                                          bytesPerRow: Self.width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
            return true
        }
        guard drawn else { return nil }
        luminance = pixels
    }

    /// 64-bit difference hash (9×8 block means, each bit "left brighter than right"): stable under small shifts and
    /// re-encoding, flips when the layout changes.
    public var dHash: UInt64 {
        let columns = 9, rows = 8
        var means = [Double](repeating: 0, count: columns * rows)
        for row in 0..<rows {
            let y0 = row * Self.height / rows, y1 = (row + 1) * Self.height / rows
            for column in 0..<columns {
                let x0 = column * Self.width / columns, x1 = (column + 1) * Self.width / columns
                var sum = 0
                for y in y0..<y1 { for x in x0..<x1 { sum += Int(luminance[y * Self.width + x]) } }
                means[row * columns + column] = Double(sum) / Double(max((y1 - y0) * (x1 - x0), 1))
            }
        }
        var hash: UInt64 = 0
        for row in 0..<rows {
            for column in 0..<(columns - 1) where means[row * columns + column] > means[row * columns + column + 1] {
                hash |= 1 << UInt64(row * 8 + column)
            }
        }
        return hash
    }
}

/// Decides whether a frame differs meaningfully from the last kept one: enough grid cells changed (a new line of
/// text, a new slide), or the coarse layout hash moved. A menu-bar clock tick or a cursor is below both thresholds.
public struct FrameChangeDetector: Sendable {
    /// A cell counts as changed when its luminance moved by more than this.
    public var cellThreshold: Int = 18
    /// …and the frame counts as changed when at least this share of cells did (0.4 % ≈ 21 of 5,184 cells).
    public var changedFraction: Double = 0.004
    /// Or when the layout hash differs in at least this many bits.
    public var hashDistance: Int = 8
    public init() {}

    public struct Difference: Sendable, Equatable {
        public var fraction: Double
        public var hashDistance: Int
    }

    public static func difference(_ a: FrameSignature, _ b: FrameSignature, cellThreshold: Int = 18) -> Difference {
        var changed = 0
        for index in a.luminance.indices where abs(Int(a.luminance[index]) - Int(b.luminance[index])) > cellThreshold {
            changed += 1
        }
        return Difference(fraction: Double(changed) / Double(a.luminance.count), hashDistance: (a.dHash ^ b.dHash).nonzeroBitCount)
    }

    public func isMeaningful(from previous: FrameSignature?, to current: FrameSignature) -> Bool {
        guard let previous else { return true }
        let difference = Self.difference(previous, current, cellThreshold: cellThreshold)
        return difference.fraction >= changedFraction || difference.hashDistance >= hashDistance
    }
}

/// Paces keyframes: look at most every `interval` seconds, keep a frame only when it changed meaningfully since the
/// last kept one. Pure state, so the capture queue can own it.
public struct KeyframeSampler: Sendable {
    public var interval: Double
    public var detector: FrameChangeDetector
    public private(set) var lastLooked: Double?
    public private(set) var lastKept: FrameSignature?
    public init(interval: Double = 2.5, detector: FrameChangeDetector = FrameChangeDetector()) {
        self.interval = interval; self.detector = detector
    }

    /// Whether a frame arriving at `time` should be looked at (converted and hashed) at all.
    public func isDue(_ time: Double) -> Bool { lastLooked.map { time - $0 >= interval } ?? true }

    /// Records the look; true when the frame should be considered for embedding.
    public mutating func consider(_ signature: FrameSignature, at time: Double) -> Bool {
        lastLooked = time
        guard detector.isMeaningful(from: lastKept, to: signature) else { return false }
        lastKept = signature
        return true
    }

    /// Forget the last kept frame (after a pause or a private app), so the next frame is kept and read again.
    public mutating func reset() { lastKept = nil }
}

/// One OCR'd keyframe.
public struct ScreenObservation: Sendable {
    public var time: Double
    public var text: String
    public var lines: [ScreenTextLine]?
    public var app: String?
    public var bundleID: String?
    public var window: String?
    public init(time: Double, text: String, lines: [ScreenTextLine]? = nil, app: String? = nil, bundleID: String? = nil, window: String? = nil) {
        self.time = time; self.text = text; self.lines = lines; self.app = app; self.bundleID = bundleID; self.window = window
    }
}

/// Merges consecutive keyframes that show (about) the same text into one `ScreenMoment`, and starts a new one when
/// the text or the app changes. A slide that builds bullet by bullet stays one moment with the fullest text.
public struct ScreenMomentBuilder: Sendable {
    /// Word-set similarity at or above which two frames are the same moment.
    public var sameThreshold: Double = 0.6
    /// A moment longer than this is closed and continued as a new one, so a link lands near the spot.
    public var maximumDuration: Double = 300
    /// Frames with fewer words than this are not moments (a video call's faces, a blank desktop).
    public var minimumWords: Int = 3
    public private(set) var closed: [ScreenMoment] = []
    public private(set) var open: ScreenMoment?
    public init() {}

    public enum Outcome: Sendable, Equatable {
        /// A new moment began (and `closed` a previous one, if any). The caller should save its thumbnail.
        case started(id: String, closed: ScreenMoment?)
        /// The frame was merged into the open moment.
        case extended(id: String)
        /// No readable text: the open moment (if any) ended here.
        case ignored(closed: ScreenMoment?)
    }

    public var all: [ScreenMoment] { closed + (open.map { [$0] } ?? []) }

    @discardableResult
    public mutating func add(_ observation: ScreenObservation, id: String = UUID().uuidString, thumbnail: String? = nil) -> Outcome {
        let text = Self.clean(observation.text)
        guard Self.words(text).count >= minimumWords else { return .ignored(closed: close(at: observation.time)) }
        if var current = open, current.bundleID == observation.bundleID,
           observation.time - current.start < maximumDuration,
           Self.similarity(current.text, text) >= sameThreshold {
            current.end = max(current.end, observation.time)
            current.frames += 1
            if text.count > current.text.count { current.text = text; current.lines = observation.lines }
            if current.window == nil { current.window = observation.window }
            open = current
            return .extended(id: current.id)
        }
        let previous = close(at: observation.time)
        open = ScreenMoment(id: id, start: observation.time, end: observation.time, text: text, lines: observation.lines,
                            app: observation.app, bundleID: observation.bundleID, window: observation.window, thumbnail: thumbnail)
        return .started(id: id, closed: previous)
    }

    /// The screen is unchanged up to `time` (no new keyframe): the open moment lasts at least until then.
    public mutating func extend(to time: Double) {
        if let current = open { open?.end = max(current.end, time) }
    }

    /// Ends the open moment at `time` (pause, a private app came forward, capture stopped). Returns it.
    @discardableResult
    public mutating func close(at time: Double) -> ScreenMoment? {
        guard var current = open else { return nil }
        current.end = max(current.end, time)
        closed.append(current); open = nil
        return current
    }

    public mutating func finish(at time: Double) -> [ScreenMoment] {
        close(at: time); return closed
    }

    // MARK: Text

    static func clean(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 }
    }

    /// Overlap of the two word sets relative to the smaller one: a slide that gains a bullet is still the same slide
    /// (1.0), a different slide shares few words.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let left = Set(words(a)), right = Set(words(b))
        guard !left.isEmpty, !right.isEmpty else { return left.isEmpty && right.isEmpty ? 1 : 0 }
        let shared = Double(left.intersection(right).count)
        // Containment, tempered by size: "Agenda" alone isn't the same moment as a full page that mentions it.
        let containment = shared / Double(min(left.count, right.count))
        let jaccard = shared / Double(left.union(right).count)
        return min(left.count, right.count) * 3 < max(left.count, right.count) ? jaccard : containment
    }
}

/// Screen moments as search chunks: one per moment (long text split), timed and linked to the transcript line
/// spoken when it appeared.
public enum ScreenChunker {
    public static let maximumCharacters = 1_200

    public static func chunks(_ moments: [ScreenMoment], meeting: Meeting, folder: URL?) -> [Chunk] {
        let segments = meeting.orderedSegments
        return moments.sorted { $0.start < $1.start }.flatMap { moment -> [Chunk] in
            guard moment.embedding != nil || ScreenMomentBuilder.words(moment.text).count >= 3 else { return [] }
            let anchor = segments.last { $0.start <= moment.start + 1 }?.id ?? segments.first?.id
            let thumbnail = moment.thumbnail.map { path in folder.map { $0.appendingPathComponent(path).path } ?? path }
            let pieces = moment.text.count > maximumCharacters
                ? TextChunker.chunks(moment.text, size: maximumCharacters, overlap: 120) : [moment.text]
            let visual = moment.embedding.map { vector in
                Chunk(kind: .screen, modality: .image, start: moment.start, end: moment.end, track: "screen",
                      anchorSegment: anchor, text: moment.context ?? "Visual scene", vector: vector,
                      thumbnail: thumbnail, window: moment.context)
            }
            let textual = (moment.text.isEmpty ? [] : pieces).map { piece in
                Chunk(kind: .screen, modality: .text, start: moment.start, end: moment.end, track: "screen",
                      anchorSegment: anchor, text: [moment.context, piece].compactMap { $0 }.joined(separator: "\n"),
                      thumbnail: thumbnail, window: moment.context)
            }
            return visual.map { [$0] + textual } ?? textual
        }
    }

    /// Folded into the meeting fingerprint (only when there are moments, so audio-only meetings keep theirs).
    public static func add(_ moments: [ScreenMoment], to hasher: inout StableHash) {
        for moment in moments.sorted(by: { $0.start < $1.start }) {
            hasher.add(moment.embeddingModelID ?? "")
            hasher.add(moment.representativeTime.map(String.init(describing:)) ?? "")
            if let vector = moment.embedding { for value in vector { hasher.add(String(value)) } }
            hasher.add(moment.id); hasher.add(moment.text); hasher.add(moment.context ?? "")
            hasher.add(String(format: "%.2f-%.2f", moment.start, moment.end)); hasher.add(moment.thumbnail ?? "")
        }
    }
}
