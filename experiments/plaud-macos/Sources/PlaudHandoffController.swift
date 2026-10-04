import Foundation
import Combine
import PlaudBleSDK

public struct HandoffDevice: Identifiable {
    public let id: String
    public let name: String
}

/// All erasing operations are confined to release(), after a fresh inventory
/// agrees with the completely downloaded and decoded local backup.
@MainActor public final class PlaudHandoffController: ObservableObject {
    @Published public private(set) var status = "Save every recording from your Note Pro to this Mac, then release it so it can pair with the Plaud iPhone app."
    @Published public private(set) var phase = "idle"
    /// Bytes received for the recording currently downloading, 0...1.
    @Published public private(set) var fileProgress = 0.0
    /// Filled once every recording is saved and verified; WorkScribe imports these.
    @Published public private(set) var saved: [PlaudSavedRecording] = []
    @Published public private(set) var devices: [HandoffDevice] = []
    @Published public private(set) var savedCount = 0
    @Published public private(set) var totalCount = 0
    @Published public private(set) var backupURL: URL?
    public var busy: Bool { ["signingIn", "scanning", "connecting", "saving", "releasing"].contains(phase) }
    public var readyToRelease: Bool { phase == "ready" }
    private let api = PlaudAuth()
    private let delegate = HandoffBLEDelegate()
    private var engine: BleAgent?
    private var found: [String: BleDevice] = [:]
    private var selected: BleDevice?
    private var session: PlaudSession?
    private var material: PlaudHandshake?
    private var savedInventory: [Int: Int] = [:]
    private var receipt: HandoffReceipt?
    private var cloudReleased = false
    private var operation: Task<Void, Never>?
    private var cancelWait: (() -> Void)?
    private var audio: NativeAudio?
    private var pendingPrepare: String?
    public init() { }

    private func error(_ message: String) -> Error { PlaudAuthError.message(message) }
    private func wait<T>(seconds: UInt64 = 30, _ install: (@escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            var finished = false
            var timeout: Task<Void, Never>?
            let finish: (Result<T, Error>) -> Void = { [weak self] result in
                guard !finished else { return }; finished = true
                timeout?.cancel(); self?.cancelWait = nil; continuation.resume(with: result)
            }
            cancelWait = { finish(.failure(CancellationError())) }
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                if !Task.isCancelled { finish(.failure(self?.error("The recorder did not reply. Keep it nearby and retry.") ?? CancellationError())) }
            }
            install(finish)
        }
    }
    private func run(_ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        operation = Task { [weak self] in
            do { try await work() }
            catch {
                guard let self else { return }
                guard !Task.isCancelled else { return }
                engine?.stopScan(); engine?.stopSyncFile()
                await audio?.finishAndWait(); audio = nil
                phase = cloudReleased ? "releaseRetry" : "error"
                status = cloudReleased ? "Plaud has released the recorder, but the Note Pro itself hasn’t confirmed. Keep it close and retry." : error.localizedDescription
            }
        }
    }
    public func scan() {
        run { [self] in
            phase = "scanning"; devices = []; found = [:]
            status = "Accessing your saved Plaud session. Approve the macOS Keychain prompt if shown."
            let restored = try await Task.detached(priority: .userInitiated) { try PlaudSessionStore().load() }.value
            try Task.checkCancellation()
            guard let restored else {
                phase = "signIn"
                status = "Sign in to your Plaud developer account to connect. Sessions last 24 hours."
                return
            }
            status = "Looking for your Note Pro…"
            session = restored
            if engine == nil {
                engine = BleAgent.shared; engine?.openLog(false); engine?.delegate = delegate; engine?.setFilter(name: nil)
                engine?.initBluetooth()
            }
            delegate.connection = { [weak self] state in Task { @MainActor in
                guard let self, state != 1 else { return }
                if self.phase == "ready" { self.phase = "error"; self.status = "The Note Pro disconnected before release. Your saved copies are safe. Scan again to reconnect before releasing it." }
            } }
            if engine?.isPoweredOn != true {
                let _: Void = try await wait { finish in
                    delegate.power = { powered in Task { @MainActor in if powered { finish(.success(())) } } }
                }
            }
            delegate.devices = { [weak self] values in Task { @MainActor in
                guard let self, self.phase == "scanning" else { return }
                for device in values where device.serialNumber.hasPrefix("881") { self.found[device.uuid] = device }
                self.devices = self.found.map { HandoffDevice(id: $0.key, name: "Note Pro · …" + $0.value.serialNumber.suffix(4)) }.sorted { $0.name < $1.name }
            } }
            engine?.startScan()
            // Stop early as soon as a device is chosen; otherwise list for 12 seconds.
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline && pendingPrepare == nil { try await Task.sleep(nanoseconds: 250_000_000) }
            engine?.stopScan(); phase = "choose"
            status = devices.isEmpty
                ? "No Note Pro found. Press its button to wake it, keep it close, and scan again. If another app on this Mac is connected to it, disconnect that app first."
                : "Choose your Note Pro."
            if let chosen = pendingPrepare { pendingPrepare = nil; Task { @MainActor in self.prepare(id: chosen) } }
        }
    }
    /// Uses the same Plaud user as the lab, so the recorder keeps the same owner.
    public func signIn(clientID: String, secret: String) {
        guard phase == "signIn" else { return }
        run { [self] in
            phase = "signingIn"; status = "Signing in to Plaud…"
            let session = try await api.authenticate(clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                                                     secret: secret, userID: PlaudIdentity().userID())
            try await Task.detached(priority: .userInitiated) { try PlaudSessionStore().save(session) }.value
            phase = "idle"; status = "Signed in. Looking for your Note Pro…"
            Task { @MainActor in self.scan() }
        }
    }
    public func prepare(id: String) {
        if phase == "scanning" { pendingPrepare = id; status = "Connecting to your Note Pro…"; return }
        run { [self] in
            guard let device = found[id], let session, let engine else { throw error("Scan for your Note Pro first.") }
            selected = device; phase = "connecting"; savedInventory = [:]; receipt = nil; cloudReleased = false; saved = []
            status = "Connecting securely…"
            let keys = try await api.prepare(session: session, serial: device.serialNumber); material = keys
            engine.setUserIdentifier("", keys.subject, false)
            engine.flutterMapData["userRSAPublicKey"] = keys.publicKey
            engine.flutterMapData["userRSAPrivateKey"] = keys.privateKey
            engine.flutterMapData["snSignature"] = keys.signature
            let _: Void = try await wait(seconds: 60) { finish in
                delegate.bind = { serial, result in Task { @MainActor in
                    guard serial == device.serialNumber, result == 0 else { finish(.failure(self.error("The signed device connection was rejected."))); return }
                    finish(.success(()))
                } }
                engine.connectBleDevice(bleDevice: device, keys.subject, "WorkScribe", false)
            }
            try await api.bind(session: session, serial: device.serialNumber)
            try await ensureIdle()
            let files = try await inventory()
            totalCount = files.count; savedCount = 0; phase = "saving"
            let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WorkScribe/Plaud Backups/" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); backupURL = folder
            for file in files {
                status = "Saving recording \(savedCount + 1) of \(totalCount)…"
                fileProgress = 0
                try await download(file, keys: keys, folder: folder)
                savedCount += 1
            }
            fileProgress = 0
            let confirmed = try await inventory()
            guard Self.fingerprint(files) == Self.fingerprint(confirmed) else { throw error("Recordings changed while saving. Prepare again to include the new files.") }
            savedInventory = Self.fingerprint(files)
            receipt = try HandoffReceipt(inventory: savedInventory, paths: files.flatMap {
                let directory = folder.appendingPathComponent(String($0.sessionId))
                return [directory.appendingPathComponent("audio.wav"), directory.appendingPathComponent("capture.payload")]
            })
            try JSONEncoder().encode(receipt).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
            saved = files.map { file in
                PlaudSavedRecording(id: "\(device.serialNumber):\(file.sessionId)",
                                    audioURL: folder.appendingPathComponent(String(file.sessionId)).appendingPathComponent("audio.wav"),
                                    recordedAt: PlaudSavedRecording.recordedAt(sessionID: file.sessionId))
            }
            phase = "ready"
            status = files.isEmpty ? "The recorder is empty. Nothing needs saving." : "All \(files.count) recordings are saved and checked on this Mac."
        }
    }
    private static func fingerprint(_ files: [BleFile]) -> [Int: Int] {
        Dictionary(files.map { ($0.sessionId, $0.size) }, uniquingKeysWith: max)
    }
    private func ensureIdle() async throws {
        let _: Void = try await wait { finish in
            delegate.state = { Task { @MainActor in finish(.success(())) } }
            engine?.getState()
        }
        guard engine?.isRecording == false else { throw error("Stop the Note Pro recording before preparing a handoff.") }
    }
    private func inventory() async throws -> [BleFile] {
        try await wait { finish in
            delegate.files = { files in Task { @MainActor in finish(.success(files)) } }
            engine?.getFileList(uid: Int(Date().timeIntervalSince1970), sessionId: 0, onlyOne: false)
        }
    }
    private func download(_ file: BleFile, keys: PlaudHandshake, folder: URL) async throws {
        guard file.size >= 512 else { throw error("A recording has an incomplete file header. It has not been cleared.") }
        let output = folder.appendingPathComponent(String(file.sessionId)).appendingPathComponent("audio.wav")
        let stream = NativeAudio(sessionID: file.sessionId, privateKey: keys.privateKey, outputURL: output); audio = stream
        let fault = HandoffAudioFault()
        stream.onError = { fault.set($0) }
        var expected = 0
        let _: Void = try await wait(seconds: 600) { finish in
            delegate.syncHead = { result in Task { @MainActor in if result != 0 { finish(.failure(self.error("Recorder rejected a file download."))) } } }
            delegate.data = { id, offset, bytes in Task { @MainActor in
                guard id == file.sessionId else { return }
                guard offset <= expected else { finish(.failure(self.error("A download has missing bytes. The recorder has not been cleared."))); return }
                expected = max(expected, offset + bytes.count); stream.accept(offset: offset, data: bytes)
                self.fileProgress = min(1, Double(expected) / Double(max(file.size, 1)))
            } }
            delegate.complete = { Task { @MainActor in finish(.success(())) } }
            engine?.syncFile(sessionId: file.sessionId, start: 0, end: 0, decode: false)
        }
        await stream.finishAndWait(); audio = nil
        if let message = fault.get() { throw error(message) }
        guard expected >= file.size else { throw error("A recording was not fully downloaded. The recorder has not been cleared.") }
        let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 44 else { throw error("A recording did not decode to audio. The recorder has not been cleared.") }
    }
    /// Called only by the user's destructive confirmation in the native sheet.
    public func release() {
        guard phase == "ready" || phase == "releaseRetry" else { return }
        run { [self] in
            guard let session, let selected, let engine else { throw error("Prepare the handoff first.") }
            phase = "releasing"; status = "Releasing Note Pro…"
            try await ensureIdle()
            guard let receipt else { throw error("Save recordings before releasing the device.") }
            try receipt.validate(inventory: Self.fingerprint(try await inventory()), recording: engine.isRecording)
            if !cloudReleased {
                try await api.unbind(session: session, serial: selected.serialNumber); cloudReleased = true
            }
            let _: Void = try await wait { finish in
                delegate.depair = { result in Task { @MainActor in
                    if result == 0 { finish(.success(())) }
                    else { finish(.failure(self.error("The recorder rejected release."))) }
                } }
                engine.depair(clear: true)
            }
            engine.disconnect(); phase = "released"
            status = "Open Plaud on your iPhone, tap Add device, and choose Note Pro."
        }
    }
    public func disconnect() {
        guard !busy else { return }
        engine?.stopScan(); engine?.disconnect()
        pendingPrepare = nil
        if phase != "released" { phase = "idle" }
    }
    public func cancelPreparation() {
        guard ["signingIn", "scanning", "connecting", "saving"].contains(phase) else { return }
        pendingPrepare = nil
        operation?.cancel(); cancelWait?()
        engine?.stopScan(); engine?.stopSyncFile(); engine?.disconnect()
        audio?.finish(); audio = nil
        phase = "idle"; fileProgress = 0
        status = "Stopped. Nothing was cleared from the Note Pro. Recordings already saved stay on this Mac."
    }
}
private final class HandoffAudioFault: @unchecked Sendable {
    private let lock = NSLock(); private var value: String?
    func set(_ text: String) { lock.lock(); value = value ?? text; lock.unlock() }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}
