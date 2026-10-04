import AppKit
import CoreAudio
import CoreGraphics
import WorkScribeCore

@MainActor
final class CallDetector {
    struct Signal { let name: String; let bundleID: String }
    struct Snapshot { let signal: Signal?; let available: Bool; let browserPermission: Bool }
    private var browserCall: Signal?
    func snapshot() -> Snapshot {
        guard #available(macOS 14.2, *) else { return Snapshot(signal: nil, available: false, browserPermission: false) }
        var address = property(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return Snapshot(signal: nil, available: false, browserPermission: CGPreflightScreenCaptureAccess())
        }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &processes) == noErr else {
            return Snapshot(signal: nil, available: false, browserPermission: CGPreflightScreenCaptureAccess())
        }
        let permission = CGPreflightScreenCaptureAccess()
        var activeBrowsers: [Signal] = []
        for process in processes {
            guard uint32(process, kAudioProcessPropertyIsRunningInput) == 1,
                  let bundle = string(process, kAudioProcessPropertyBundleID), bundle != Bundle.main.bundleIdentifier else { continue }
            if let name = CallApplicationPolicy.nativeName(bundleID: bundle) {
                return Snapshot(signal: Signal(name: name, bundleID: bundle), available: true, browserPermission: permission)
            }
            if let name = CallApplicationPolicy.browserName(bundleID: bundle) { activeBrowsers.append(Signal(name: name, bundleID: bundle)) }
        }
        // Once observed, a browser call remains eligible while it holds its mic,
        // even if another tab or window becomes frontmost.
        if let browserCall, activeBrowsers.contains(where: { $0.name == browserCall.name }) {
            return Snapshot(signal: browserCall, available: true, browserPermission: permission)
        }
        browserCall = nil
        if permission && !activeBrowsers.isEmpty {
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            for window in windows {
                guard let title = window[kCGWindowName as String] as? String, CallApplicationPolicy.isMeetingWindow(title),
                      let pid = window[kCGWindowOwnerPID as String] as? Int32,
                      let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                      let name = CallApplicationPolicy.browserName(bundleID: bundle),
                      let active = activeBrowsers.first(where: { $0.name == name }) else { continue }
                browserCall = active
                return Snapshot(signal: active, available: true, browserPermission: permission)
            }
        }
        return Snapshot(signal: nil, available: true, browserPermission: permission)
    }
    private func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    private func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = property(selector), value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
    private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = property(selector), value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
