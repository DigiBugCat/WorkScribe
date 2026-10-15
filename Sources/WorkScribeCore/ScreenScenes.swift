import Foundation

/// Pure, bounded temporal state. Pixel differences decide when to call the model, never where a scene ends.
public struct ScreenSceneDetector: Sendable {
    public struct Configuration: Sendable {
        // Calibrated with --bench-scenes on an M4 Max (2026-10-15): 4/4 boundaries, 0 false, held-out cases included.
        public var boundaryCosine: Float = 0.91
        public var returnCosine: Float = 0.935
        public var minimumDwell: Double = 5
        public var confirmations: Int = 2
        public init() {}
    }
    public struct Observation: Sendable {
        public var time: Double
        public var vector: [Float]
        public var frameID: String
        /// Similarity to the preceding sampled pixels. The most settled frame represents the scene.
        public var stability: Double
        public var app: String?
        public var bundleID: String?
        public var window: String?
        public init(time: Double, vector: [Float], frameID: String = UUID().uuidString, stability: Double = 0,
                    app: String? = nil, bundleID: String? = nil, window: String? = nil) {
            self.time = time; self.vector = vector; self.frameID = frameID; self.stability = stability
            self.app = app; self.bundleID = bundleID; self.window = window
        }
    }
    private struct State: Sendable {
        var moment: ScreenMoment
        var sum: [Float]
        var representative: String
        var stability: Double
        var frozen = false
        var count = 1
        var centroid: [Float] { VectorMath.normalized(sum)! }
    }
    public var configuration: Configuration
    public private(set) var closed: [ScreenMoment] = []
    private var current: State?
    private var candidate: State?
    private var lastTime: Double = -.infinity
    public init(configuration: Configuration = Configuration()) { self.configuration = configuration }
    public var open: ScreenMoment? { current?.moment }
    public var all: [ScreenMoment] { closed + (open.map { [$0] } ?? []) }
    public var needsConfirmation: Bool { candidate != nil }
    /// At most two images need to remain in memory, regardless of meeting length.
    public var representatives: [String: String] {
        var result: [String: String] = [:]
        for state in [current, candidate].compactMap({ $0 }) { result[state.moment.id] = state.representative }
        return result
    }
    public mutating func freezeRepresentative(_ id: String) {
        if current?.moment.id == id { current?.frozen = true }
    }
    public mutating func extend(to time: Double) {
        // An unresolved transition belongs to neither scene until it settles.
        if candidate == nil, time.isFinite, let end = current?.moment.end { current?.moment.end = max(end, time) }
    }
    @discardableResult public mutating func add(_ observation: Observation, modelID: String) -> Bool {
        guard observation.time.isFinite, observation.time > lastTime, observation.vector.count == 768,
              let vector = VectorMath.normalized(observation.vector) else { return false }
        lastTime = observation.time
        var o = observation; o.vector = vector
        guard var active = current else { current = make(o, modelID: modelID); return true }
        let sameApp = active.moment.bundleID == o.bundleID
        let similarity = VectorMath.dot(active.centroid, vector)
        if sameApp && similarity >= configuration.returnCosine {
            candidate = nil
            merge(o, into: &active); current = active
        } else if !sameApp || similarity < configuration.boundaryCosine || candidate != nil {
            if var pending = candidate, pending.moment.bundleID == o.bundleID,
               VectorMath.dot(pending.centroid, vector) >= configuration.boundaryCosine {
                merge(o, into: &pending); candidate = pending
            } else { candidate = make(o, modelID: modelID) }
            if let pending = candidate, pending.count >= configuration.confirmations,
               o.time - pending.moment.start >= configuration.minimumDwell {
                active.moment.end = pending.moment.start
                closed.append(active.moment); current = pending; candidate = nil
            }
        } else {
            // Hysteresis band: do not drift the centroid toward an unconfirmed transition.
            active.moment.end = o.time; current = active
        }
        return true
    }
    @discardableResult public mutating func close(at time: Double) -> ScreenMoment? {
        defer { current = nil; candidate = nil }
        guard var state = current else { return nil }
        state.moment.end = max(state.moment.start, candidate?.moment.start ?? time)
        closed.append(state.moment)
        return state.moment
    }
    public mutating func finish(at time: Double) -> [ScreenMoment] { close(at: time); return closed }
    private func make(_ o: Observation, modelID: String) -> State {
        let id = UUID().uuidString
        var moment = ScreenMoment(id: id, start: o.time, end: o.time, text: "", app: o.app,
                                  bundleID: o.bundleID, window: o.window, thumbnail: ScreenFiles.thumbnail(id))
        moment.embedding = o.vector; moment.embeddingModelID = modelID
        moment.representativeTime = o.time; moment.keyframe = ScreenFiles.keyframe(id)
        return State(moment: moment, sum: o.vector, representative: o.frameID, stability: o.stability)
    }
    private func merge(_ o: Observation, into state: inout State) {
        state.count += 1; state.moment.frames += 1; state.moment.end = o.time
        // Cap the centroid's inertia so long scenes can follow gradual motion without accumulating unbounded sums.
        let weight = Float(min(state.count - 1, 32))
        state.sum = zip(state.centroid, o.vector).map { $0 * weight + $1 }
        if !state.frozen && o.stability > state.stability {
            state.stability = o.stability; state.representative = o.frameID
            state.moment.embedding = o.vector; state.moment.representativeTime = o.time
        }
    }
}

/// Existing realrun levels, with screen work shed before audio. Thermal pressure has the same precedence.
public struct ScreenWorkBudget: Equatable, Sendable {
    public var sampleInterval: Double
    public var embeddings: Bool
    public var ocr: Bool
    public init(pressure: RecordingPressure, thermalLevel: Int = 0, baseInterval: Double = 2.5) {
        sampleInterval = pressure >= .screenPaused || thermalLevel >= 1 ? baseInterval * 3 : baseInterval
        embeddings = pressure < .aiPaused && thermalLevel < 2
        ocr = pressure == .normal && thermalLevel == 0
    }
}

extension ScreenFiles {
    /// OCR uses a readable frame, never the small display thumbnail.
    public static func keyframe(_ sceneID: String) -> String { "\(thumbnails)/\(sceneID)-frame.jpg" }
    /// Serializes scene writes with raw-data deletion, including late OCR completions.
    public static let mutationLock = NSRecursiveLock()
}

public enum ScreenSceneRetrieval {
    /// Keyword evidence is optional; visual matching works even before the one OCR pass.
    public static func ranked(_ scenes: [ScreenMoment], question: String, vector: [Float]? = nil,
                              modelID: String? = nil, at time: Double? = nil, limit: Int = 3) -> [ScreenMoment] {
        let lexical = (try? LexicalMatcher().similarities(notes: [question], chunks: scenes.map(\.searchText)).first) ?? []
        return scenes.enumerated().compactMap { i, scene -> (ScreenMoment, Double)? in
            let wordScore = i < lexical.count ? lexical[i] : 0
            var meaning = 0.0
            if let vector, let stored = scene.embedding, stored.count == vector.count,
               scene.embeddingModelID == modelID { meaning = Double(VectorMath.dot(stored, vector)) }
            let nearby = time.map { $0 >= scene.start && $0 <= scene.end + 10 } ?? false
            guard nearby || wordScore > 0.1 || meaning > 0.35 else { return nil }
            return (scene, max(wordScore, meaning) + (nearby ? 1 : 0))
        }.sorted { $0.1 == $1.1 ? $0.0.start < $1.0.start : $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}
