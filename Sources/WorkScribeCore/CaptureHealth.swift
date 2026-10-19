import Foundation

/// Which audio sources a recording actually has, and what to tell the person about it.
/// A recording fails only when no source works: a broken microphone must never cost the call
/// audio, and missing Screen Recording permission must never cost the microphone.
public struct CaptureHealth: Equatable, Sendable {
    public enum Microphone: Equatable, Sendable {
        case working
        /// Could not be opened (permission, no device, CoreAudio refused the aggregate device).
        case unavailable(String)
        /// Opened, but every sample is exactly zero: a muted interface, a virtual device with
        /// nothing routed into it, or a privacy kill switch. Not a quiet room.
        case silent(device: String?)
    }
    public var microphone: Microphone
    public var systemRequested: Bool
    public var systemWorking: Bool
    public init(microphone: Microphone, systemRequested: Bool, systemWorking: Bool) {
        self.microphone = microphone; self.systemRequested = systemRequested; self.systemWorking = systemWorking
    }
    public var microphoneWorking: Bool { microphone == .working }
    public var microphoneOpen: Bool { if case .unavailable = microphone { return false }; return true }
    public var canRecord: Bool { microphoneOpen || systemWorking }

    /// The single status line while recording. Nil when everything works (the normal message stands).
    public var degradedMessage: String? {
        switch microphone {
        case .working: return nil
        case .unavailable: return systemWorking ? "Recording call audio · your mic isn’t available" : nil
        case .silent(let device):
            let name = device.map { "“\($0)”" } ?? "your mic"
            return systemWorking ? "Recording call audio · \(name) is sending only silence"
                                 : "\(name.prefix(1).uppercased() + name.dropFirst()) is sending only silence · check your input in System Settings › Sound"
        }
    }
}

/// Counts exact-zero input. Thread-confined to its owner (the audio track's lock).
public struct SilenceMeter: Sendable {
    public private(set) var frames = 0
    public private(set) var audibleFrames = 0
    public init() {}
    public mutating func add<C: Collection>(_ samples: C) where C.Element == Int16 {
        frames += samples.count
        if samples.contains(where: { $0 != 0 }) { audibleFrames += samples.count }
    }
    /// After `seconds` of input at `rate`, not one non-zero sample.
    public func isDigitalSilence(after seconds: Double = 8, rate: Double = 16_000) -> Bool {
        Double(frames) >= seconds * rate && audibleFrames == 0
    }
}
