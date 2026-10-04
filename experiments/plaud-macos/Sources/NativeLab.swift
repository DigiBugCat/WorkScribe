import AppKit
import SwiftUI
import CoreBluetooth
import PlaudBleSDK

struct NearbyRecorder: Identifiable {
    var id: String
    var name: String
    var serialSuffix: String
    var signal: Int
}

@MainActor final class LabModel: ObservableObject {
    static let shared = LabModel()
    @Published var status = "Ready to test native Bluetooth"
    @Published var scanning = false
    @Published var devices: [NearbyRecorder] = []
    @Published var authenticated = false
    @Published var authenticating = false
    @Published var authStatus = "Developer session not configured"
    @Published var preparedDeviceID: String?
    @Published var preparing = false
    @Published var connected = false
    @Published var connecting = false
    @Published var recording = false
    @Published var processing = false
    @Published var audioSeconds = 0.0
    @Published var audioPackets = 0
    @Published var transcript = ""
    @Published var partial = ""
    @Published var stages: [String] = []
    private var preparedHandshake: PlaudHandshake?
    private let auth = PlaudAuth()
    private var session: PlaudSession?
    private let sessionStore = PlaudSessionStore()
    private let callbacks = NativeBLEDelegate()
    private var engine: BleAgent?
    private var timeout: Task<Void, Never>?
    private var recordTimeout: Task<Void, Never>?
    private var tailTimeout: Task<Void, Never>?
    private var wantsScan = false
    private var found: [String: BleDevice] = [:]
    private var activeDevice: BleDevice?
    private var audio: NativeAudio?
    private var activeSessionID: Int?
    private var captureRequested = false
    private var ending = false
    private let speech = NativeSpeech()
    private var speechInput: AsyncStream<Data>.Continuation?
    private var audioFolder: URL?
    private var transcriptEvents: [[String: Any]] = []
    private var hadError = false
    private let reportURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/WorkScribePlaudLab/status.json")
    var userID: String {
        if let existing = UserDefaults.standard.string(forKey: "plaud.native.userID") { return existing }
        let created = "workscribe-" + UUID().uuidString
        UserDefaults.standard.set(created, forKey: "plaud.native.userID")
        return created
    }
    init() {
        do {
            if let saved = try sessionStore.load() {
                session = saved; authenticated = true; authStatus = "Authenticated · restored from Keychain"
            }
        } catch { authStatus = error.localizedDescription }
        callbacks.onPower = { [weak self] value in DispatchQueue.main.async { self?.powerChanged(value) } }
        callbacks.onDevices = { [weak self] values in DispatchQueue.main.async { self?.receive(values) } }
        callbacks.onBind = { [weak self] serial, status in DispatchQueue.main.async { self?.bound(serial: serial, result: status) } }
        callbacks.onWait = { [weak self] seconds in DispatchQueue.main.async {
            self?.status = "Confirm the connection on your Note Pro (\(seconds) seconds)."; self?.writeReport()
        } }
        callbacks.onDiagnostic = { [weak self] value in DispatchQueue.main.async { self?.stages.append(value); self?.writeReport() } }
        callbacks.onConnection = { [weak self] value in DispatchQueue.main.async { self?.connectionChanged(value) } }
        callbacks.onStage = { [weak self] stage, detail in DispatchQueue.main.async {
            guard let self else { return }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
            let clean = (detail ?? "").unicodeScalars.filter { allowed.contains($0) }.map(String.init).joined()
            self.stages.append(String((stage + (clean.isEmpty ? "" : ": " + clean)).prefix(100)))
            self.stages = Array(self.stages.suffix(12)); self.writeReport()
        } }
        callbacks.onStart = { [weak self] id, result in DispatchQueue.main.async { self?.recordStarted(id: id, result: result) } }
        callbacks.onStop = { [weak self] id in DispatchQueue.main.async { self?.recordStopped(id: id) } }
        callbacks.onData = { [weak self] id, offset, bytes in DispatchQueue.main.async {
            guard self?.activeSessionID == id else { return }; self?.audio?.accept(offset: offset, data: bytes)
        } }
        callbacks.onComplete = { [weak self] in DispatchQueue.main.async {
            guard let self, !self.recording, self.captureRequested else { return }; self.finishCapture(tailConfirmed: true)
        } }
        speech.onEvent = { [weak self] event in
            guard let self else { return }
            if (event["type"] as? String)?.hasSuffix("completed") == true {
                self.transcriptEvents.append(event)
                self.transcript += (self.transcript.isEmpty ? "" : "\n") + (event["transcript"] as? String ?? "")
                self.partial = ""
            } else { self.partial = event["transcript"] as? String ?? "" }
            self.writeReport()
        }
        speech.onError = { [weak self] error in self?.fail("Speech: " + error) }
        writeReport()
    }
    func authenticate(clientID: String, secret: String) async {
        authenticating = true; authStatus = "Authenticating with Plaud…"
        defer { authenticating = false }
        do {
            let result = try await auth.authenticate(clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines), secret: secret, userID: userID)
            try sessionStore.save(result); session = result; authenticated = true
            authStatus = "Authenticated · session saved in Keychain"
        } catch { authStatus = error.localizedDescription }
        writeReport()
    }
    func prepareDevice(_ id: String) async {
        guard let session, let device = found[id], !captureRequested else { return }
        preparing = true; preparedDeviceID = nil; preparedHandshake = nil; hadError = false
        status = "Requesting and validating signed device keys…"; writeReport()
        defer { preparing = false }
        do {
            let material = try await auth.prepare(session: session, serial: device.serialNumber)
            // Verify the server-issued pair locally before any device mutation.
            // No keys, ciphertext, or arbitrary error descriptions enter logs.
            do {
                let privateKey = try PrivateKey(pemEncoded: material.privateKey)
                let publicKey = try PublicKey(pemEncoded: material.publicKey)
                let clear = ClearMessage(data: Data("WorkScribe native key check".utf8))
                let encrypted = try clear.encrypted(with: publicKey, padding: .PKCS1)
                let decoded = try encrypted.decrypted(with: privateKey, padding: .PKCS1)
                guard decoded.data == clear.data else { throw PlaudAuthError.message("key mismatch") }
            } catch {
                throw PlaudAuthError.message("The server-issued RSA key pair failed local validation. No connection was attempted.")
            }
            preparedHandshake = material; preparedDeviceID = id
            status = "Device keys ready. Choose Connect to pair this recorder."
        } catch { status = error.localizedDescription; hadError = true }
        writeReport()
    }
    func connectPrepared() {
        guard let id = preparedDeviceID, let device = found[id], let material = preparedHandshake,
              let session, let engine, !connecting, !connected else { return }
        timeout?.cancel(); engine.stopScan(); scanning = false; wantsScan = false
        BLETrace.install(); BLETrace.reset(); BLETrace.enabled = true
        BLETrace.onChange = { [weak self] in DispatchQueue.main.async { self?.writeReport() } }
        activeDevice = device; connecting = true; hadError = false; stages = []
        status = "Connecting to Note Pro…"
        engine.openLog(false)
        BLETrace.startSDKDiagnostics()
        // The SDK's user-token initializer passes an empty legacy app key.
        engine.setUserIdentifier("", material.subject, false)
        engine.flutterMapData["userRSAPublicKey"] = material.publicKey
        engine.flutterMapData["userRSAPrivateKey"] = material.privateKey
        engine.flutterMapData["snSignature"] = material.signature
        // Normal authenticated handshake only. Never force-clear another owner.
        engine.connectBleDevice(bleDevice: device, material.subject, "WorkScribe", false)
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled, let self, self.connecting else { return }
            self.connecting = false
            let rsaFailure = BLETrace.snapshot().contains("sdk: RSA-decryption failed")
            self.fail(rsaFailure ? "The recorder replied, but the encrypted handshake failed. Check its existing app binding before retrying." : "Device handshake timed out. Check the recorder and retry.")
            self.engine?.disconnect()
        }
        writeReport()
    }
    private func bound(serial: String?, result: Int) {
        guard connecting, let device = activeDevice, let session else { return }
        guard result == 0, serial == device.serialNumber else {
            connecting = false; fail("Device rejected the authenticated handshake (status \(result))."); engine?.disconnect(); return
        }
        timeout?.cancel(); BLETrace.enabled = false
        status = "Registering the authenticated device connection…"; writeReport()
        Task {
            do {
                try await auth.bind(session: session, serial: device.serialNumber)
                connected = true; connecting = false; status = "Note Pro connected natively to this Mac"
                engine?.getState(); writeReport()
            } catch { connecting = false; fail(error.localizedDescription); engine?.disconnect() }
        }
    }
    private func connectionChanged(_ value: Int) {
        if value == 0 || value == 2 || value < 0 {
            connected = false; connecting = false
            if captureRequested { fail("Bluetooth disconnected during capture") }
            else if !hadError { status = "Bluetooth disconnected. Check the connection stages below."; writeReport() }
        }
    }
    func startTest() async {
        guard connected, !captureRequested, engine?.isRecording != true else {
            status = "The recorder is already recording or is not connected."; writeReport(); return
        }
        captureRequested = true; processing = true; hadError = false; ending = false
        transcript = ""; partial = ""; transcriptEvents = []; audioSeconds = 0; audioPackets = 0
        status = "Preparing local speech engine…"; writeReport()
        do {
            speechInput = try await speech.start()
            guard connected else { throw CaptureError.message("Device disconnected before the test") }
            status = "Starting a 15-second test recording…"; engine?.startRecord(); writeReport()
        } catch { fail(error.localizedDescription) }
    }
    private func recordStarted(id: Int, result: Int) {
        guard captureRequested else { return }
        guard result == 0, id > 0, let material = preparedHandshake else { fail("The recorder did not start the test"); return }
        activeSessionID = id; recording = true
        let folder = reportURL.deletingLastPathComponent().appendingPathComponent("Recordings/" + UUID().uuidString)
        audioFolder = folder
        let stream = NativeAudio(sessionID: id, privateKey: material.privateKey, outputURL: folder.appendingPathComponent("plaud.wav"))
        let input = speechInput
        stream.onPCM = { [weak self] bytes in
            if case .dropped = input?.yield(bytes) { DispatchQueue.main.async { self?.fail("Audio arrived faster than the speech engine could process it") } }
        }
        stream.onStatus = { [weak self] seconds, packets in DispatchQueue.main.async {
            self?.audioSeconds = seconds; self?.audioPackets = packets; self?.writeReport()
        } }
        stream.onError = { [weak self] error in DispatchQueue.main.async { self?.fail(error) } }
        audio = stream
        status = "Recording and transcribing locally…"; writeReport()
        engine?.syncFile(sessionId: id, start: 0, end: 0, decode: false)
        recordTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if !Task.isCancelled { self?.stopTest() }
        }
    }
    func stopTest() {
        guard captureRequested else { return }
        if recording, activeSessionID == engine?.sessionId { engine?.stopRecord() }
        else { finishCapture(tailConfirmed: false) }
    }
    private func recordStopped(id: Int) {
        guard captureRequested, id == activeSessionID else { return }
        recording = false; recordTimeout?.cancel()
        status = "Receiving the last audio packets…"; writeReport()
        tailTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { self?.finishCapture(tailConfirmed: false) }
        }
    }
    private func finishCapture(tailConfirmed: Bool) {
        guard captureRequested, !ending else { return }; ending = true
        recordTimeout?.cancel(); tailTimeout?.cancel(); engine?.stopSyncFile(); recording = false
        let stream = audio; audio = nil
        Task {
            await stream?.finishAndWait()
            await speech.finish(); speechInput = nil
            if let folder = audioFolder {
                try? JSONSerialization.data(withJSONObject: transcriptEvents, options: .prettyPrinted)
                    .write(to: folder.appendingPathComponent("transcript.json"), options: .atomic)
            }
            captureRequested = false; processing = false; activeSessionID = nil
            if !hadError { status = tailConfirmed ? "Test saved. Final transfer confirmed." : "Test saved. Final transfer marker was not received." }
            writeReport()
        }
    }
    private func fail(_ text: String) {
        hadError = true; status = text
        if recording, activeSessionID == engine?.sessionId { engine?.stopRecord() }
        if captureRequested { finishCapture(tailConfirmed: false) }
        writeReport()
    }
    func scan() {
        guard !scanning, !connecting, !connected else { return }
        wantsScan = true; scanning = true; devices = []; found = [:]; hadError = false
        status = "Preparing native Bluetooth…"; writeReport()
        if engine == nil {
            engine = BleAgent.shared; engine?.openLog(false); engine?.delegate = callbacks
            engine?.setFilter(name: nil); engine?.initBluetooth()
        }
        if engine?.isPoweredOn == true { beginScan() }
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            if !Task.isCancelled { self?.stop() }
        }
    }
    func stop() {
        wantsScan = false; engine?.stopScan(); scanning = false; timeout?.cancel()
        if !preparing && preparedDeviceID == nil && !hadError {
            status = devices.isEmpty ? "Scan finished. No Plaud recorder found." : "Scan finished. Found \(devices.count) recorder(s)."
        }
        writeReport()
    }
    private func powerChanged(_ powered: Bool) {
        if powered && wantsScan { beginScan() }
        else if !powered {
            let auth = CBManager.authorization
            status = auth == .denied || auth == .restricted ? "Bluetooth permission is required in System Settings." : "Bluetooth is not ready. Turn it on to scan."
            writeReport()
        }
    }
    private func beginScan() { engine?.startScan(); status = "Scanning for your Plaud Note Pro…"; writeReport() }
    private func receive(_ values: [BleDevice]) {
        for device in values {
            let key = device.uuid.isEmpty ? device.serialNumber : device.uuid
            if !key.isEmpty { found[key] = device }
        }
        devices = found.map { key, value in NearbyRecorder(id: key, name: value.name,
            serialSuffix: String(value.serialNumber.suffix(4)), signal: Int(value.rssi)) }.sorted { $0.signal > $1.signal }
        if !preparing && preparedDeviceID == nil && !hadError { status = "Found \(devices.count) Plaud recorder(s)" }
        writeReport()
    }
    func shutdown() async {
        timeout?.cancel(); recordTimeout?.cancel(); tailTimeout?.cancel()
        if recording, activeSessionID == engine?.sessionId { engine?.stopRecord() }
        if captureRequested {
            finishCapture(tailConfirmed: false)
            for _ in 0..<100 where processing { try? await Task.sleep(nanoseconds: 50_000_000) }
        }
        engine?.disconnect(); await speech.shutdown()
    }
    private func writeReport() {
        let value: [String: Any] = ["status": status, "scanning": scanning, "connected": connected,
            "connecting": connecting, "recording": recording, "processing": processing,
            "audio_seconds": audioSeconds, "audio_packets": audioPackets, "final_transcript_segments": transcriptEvents.count,
            "bluetooth_authorization": CBManager.authorization.rawValue, "authenticated": authenticated,
            "auth_status": authStatus, "device_keys_ready": preparedDeviceID != nil, "stages": stages, "transport": BLETrace.snapshot(),
            "devices": devices.map { ["name": $0.name, "serial_suffix": $0.serialSuffix, "signal": $0.signal] as [String: Any] }]
        do {
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)
        } catch { }
    }
}

struct LabView: View {
    @StateObject private var model = LabModel.shared
    @State private var clientID = ""
    @State private var secret = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Plaud · Native Mac Lab").font(.title2.bold())
            Text(model.status).font(.headline).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(model.scanning ? "Stop scan" : "Scan for Plaud") { if model.scanning { model.stop() } else { model.scan() } }
                    .disabled(model.connected || model.connecting)
                if model.preparedDeviceID != nil && !model.connected {
                    Button(model.connecting ? "Connecting…" : "Connect") { model.connectPrepared() }.disabled(model.connecting)
                }
                if model.connected {
                    Button(model.recording ? "Stop test" : "Record 15-second test") {
                        if model.recording { model.stopTest() } else { Task { await model.startTest() } }
                    }.disabled(model.processing && !model.recording)
                }
            }
            ForEach(model.devices) { device in
                HStack {
                    Text(device.name.isEmpty ? "Plaud recorder" : device.name)
                    Text("…\(device.serialSuffix) · \(device.signal) dBm").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.preparedDeviceID == device.id ? "Keys ready" : "Prepare") { Task { await model.prepareDevice(device.id) } }
                        .disabled(!model.authenticated || model.preparing || model.preparedDeviceID == device.id || model.connected)
                }
            }
            if !model.stages.isEmpty { Text(model.stages.suffix(4).joined(separator: "\n")).font(.caption.monospaced()).foregroundStyle(.secondary) }
            if model.processing || model.audioPackets > 0 {
                Text(String(format: "%.1f seconds of PCM · %d packets", model.audioSeconds, model.audioPackets)).font(.caption)
                ScrollView { Text(model.transcript + (model.partial.isEmpty ? "" : "\n" + model.partial)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(height: 120)
            }
            Divider()
            DisclosureGroup("Developer authentication") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Client ID", text: $clientID).textFieldStyle(.roundedBorder)
                    SecureField("Client secret", text: $secret).textFieldStyle(.roundedBorder)
                    Button(model.authenticating ? "Authenticating…" : "Authenticate and save session") {
                        let enteredSecret = secret; secret = ""
                        Task { await model.authenticate(clientID: clientID, secret: enteredSecret) }
                    }.disabled(model.authenticating || clientID.isEmpty || secret.isEmpty || model.connected)
                    Text("Sends credentials only to Plaud. Stores the returned session in this Mac’s Keychain; the client secret is not saved.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 8)
            }
            Text(model.authStatus).font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 500).frame(minHeight: 340)
    }
}
final class LabDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in await LabModel.shared.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
@main struct NativeLab: App {
    @NSApplicationDelegateAdaptor(LabDelegate.self) var delegate
    var body: some Scene { WindowGroup { LabView() }.windowResizability(.contentSize) }
}
