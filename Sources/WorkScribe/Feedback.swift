import AppKit
import Carbon.HIToolbox
import UserNotifications

/// Input loudness per source while recording. Kept apart from AppModel so a
/// 10 Hz meter refresh only redraws the meters, not the transcript.
@MainActor final class LevelMonitor: ObservableObject {
    @Published var microphone: Float = 0
    @Published var system: Float?
    func reset() { microphone = 0; system = nil }
    func update(microphone mic: Float, system sys: Float?) {
        // Rise immediately, fall gently, so speech reads as movement rather than flicker.
        microphone = max(mic, microphone * 0.8)
        system = sys.map { max($0, (system ?? 0) * 0.8) }
    }
}

/// A speaker-name change that can still be undone from the toast.
struct SpeakerToast: Identifiable, Equatable {
    let id = UUID()
    let meetingID: String
    let text: String
}

/// Local notifications for events that happen while the popover is closed.
enum Notifier {
    /// Notifications need a real app bundle; command-line checks and tests skip them.
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }
    static func post(_ title: String, _ body: String) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

/// System-wide ⌥⌘R. Carbon hot keys need no Accessibility permission.
final class GlobalHotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init?(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue().action()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let identifier = EventHotKeyID(signature: OSType(0x5753_4352), id: 1) // "WSCR"
        let registered = RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(cmdKey | optionKey), identifier,
                                             GetApplicationEventTarget(), 0, &reference)
        guard installed == noErr, registered == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
    }
    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
