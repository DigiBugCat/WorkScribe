import Foundation
import PlaudBleSDK

/// Incremental Ogg lacing, including packets that cross page boundaries.
struct OggPackets {
    private var buffer = Data()
    private var partials: [UInt32: Data] = [:]
    private var sequences: [UInt32: UInt32] = [:]
    private var audioSerial: UInt32?
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        guard buffer.count <= 2 * 1024 * 1024 else { throw PlaudAuthError.message("Ogg input exceeded its buffer limit") }
        var packets: [Data] = []
        while buffer.count >= 27 {
            guard buffer.prefix(4) == Data("OggS".utf8), buffer[4] == 0 else { throw PlaudAuthError.message("Invalid decoded Ogg audio") }
            let segments = Int(buffer[26]), header = 27 + segments
            guard buffer.count >= header else { break }
            let lacing = Array(buffer[27..<header])
            let size = header + lacing.reduce(0) { $0 + Int($1) }
            guard buffer.count >= size else { break }
            // Ogg verifies the decrypted payload as well as framing.
            let expected = (0..<4).reduce(UInt32(0)) { $0 | UInt32(buffer[22+$1]) << UInt32($1*8) }
            var page = Data(buffer.prefix(size)); page.replaceSubrange(22..<26, with: [UInt8](repeating: 0, count: 4))
            var crc: UInt32 = 0
            for byte in page {
                crc ^= UInt32(byte) << 24
                for _ in 0..<8 { crc = crc & 0x80000000 != 0 ? (crc << 1) ^ 0x04c11db7 : crc << 1 }
            }
            guard crc == expected else { throw PlaudAuthError.message("Ogg checksum failed after audio decryption") }
            func u32(_ at: Int) -> UInt32 {
                (0..<4).reduce(UInt32(0)) { $0 | UInt32(buffer[at+$1]) << UInt32($1*8) }
            }
            let serial = u32(14), sequence = u32(18)
            guard sequences.count < 16 || sequences[serial] != nil else { throw PlaudAuthError.message("Too many Ogg logical streams") }
            if let previous = sequences[serial], sequence != previous &+ 1 {
                throw PlaudAuthError.message("Ogg logical-stream sequence gap")
            }
            sequences[serial] = sequence
            var packet = partials[serial] ?? Data()
            let continued = buffer[5] & 1 != 0
            guard continued == !packet.isEmpty else { throw PlaudAuthError.message("Missing Ogg packet continuation") }
            var position = header
            for length in lacing {
                let end = position + Int(length)
                packet.append(buffer[position..<end]); position = end
                guard packet.count <= 1024 * 1024 else { throw PlaudAuthError.message("Ogg packet exceeded its buffer limit") }
                if length < 255 {
                    if audioSerial == nil, packet.prefix(8) == Data("OpusHead".utf8) { audioSerial = serial }
                    if serial == audioSerial { packets.append(packet) }
                    packet = Data()
                }
            }
            partials[serial] = packet
            buffer = Data(buffer.dropFirst(size))
        }
        return packets
    }
}

final class PCMFile {
    let url: URL
    let channels: Int
    private let handle: FileHandle
    private(set) var bytes: UInt32 = 0
    init(url: URL, channels: Int) throws {
        self.url = url; self.channels = channels
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(bytes: 0, channels: channels))
    }
    func append(_ data: Data) throws {
        guard UInt64(bytes) + UInt64(data.count) <= UInt64(UInt32.max) - 36 else { throw PlaudAuthError.message("Recording reached WAV size limit") }
        try handle.write(contentsOf: data); bytes += UInt32(data.count)
    }
    func close() throws {
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(bytes: bytes, channels: channels))
        try handle.synchronize(); try handle.close()
    }
    static func header(bytes: UInt32, channels: Int) -> Data {
        var data = Data("RIFF".utf8)
        func u32(_ value: UInt32) { var value = value.littleEndian; data.append(Data(bytes: &value, count: 4)) }
        func u16(_ value: UInt16) { var value = value.littleEndian; data.append(Data(bytes: &value, count: 2)) }
        u32(bytes+36); data.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(UInt16(channels)); u32(16000)
        u32(UInt32(16000*channels*2)); u16(UInt16(channels*2)); u16(16); data.append(Data("data".utf8)); u32(bytes)
        return data
    }
}

final class NativeAudio {
    let sessionID: Int
    private let queue = DispatchQueue(label: "WorkScribe.plaud.audio")
    private let encrypted: EncryptedStream
    private let outputURL: URL
    private let decoder = JXAvcDecoder()
    private var oggDecoder: OpusPacketDecoder?
    private var file: PCMFile?
    private var compressedFile: FileHandle?
    private var framing = OggPackets()
    private var pending = Data()
    private var isOgg: Bool?
    private var closed = false
    private var packets = 0
    private var lastReport = Date.distantPast
    var onPCM: ((Data) -> Void)?
    var onStatus: ((Double, Int) -> Void)?
    var onError: ((String) -> Void)?
    init(sessionID: Int, privateKey: String, outputURL: URL) {
        self.sessionID = sessionID; self.outputURL = outputURL
        encrypted = EncryptedStream(privateKey: privateKey)
    }
    func accept(offset: Int, data: Data) {
        queue.async { [self] in
            guard !closed else { return }
            do {
                for packet in try encrypted.accept(offset: offset, bytes: data) { try compressed(packet.bytes) }
            } catch { onError?(error.localizedDescription); finishOnQueue() }
        }
    }
    private func compressed(_ bytes: Data) throws {
        if file == nil {
            file = try PCMFile(url: outputURL, channels: encrypted.channels)
            decoder.createDecoderIfNeed(encrypted.channels)
            let path = outputURL.deletingLastPathComponent().appendingPathComponent("capture.payload")
            FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600])
            compressedFile = try FileHandle(forWritingTo: path)
        }
        // Local test evidence allows decoder repair without another recording.
        try compressedFile?.write(contentsOf: bytes)
        pending.append(bytes)
        if isOgg == nil {
            guard pending.count >= 4 else { return }
            isOgg = pending.prefix(4) == Data("OggS".utf8)
            let metadata: [String: Any] = ["channels": encrypted.channels, "container": isOgg == true ? "ogg" : "fixed-opus"]
            try JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted)
                .write(to: outputURL.deletingLastPathComponent().appendingPathComponent("audio-format.json"))
        }
        if isOgg == true {
            let frames = try framing.append(pending); pending = Data()
            for frame in frames {
                if frame.prefix(8) == Data("OpusHead".utf8) {
                    guard frame.count >= 19, Int(frame[9]) == encrypted.channels else { throw PlaudAuthError.message("Audio channel metadata disagrees") }
                    oggDecoder = try OpusPacketDecoder(header: frame, expectedChannels: encrypted.channels)
                } else if frame.prefix(8) != Data("OpusTags".utf8) { try decode(frame) }
            }
        } else {
            let size = 80 * encrypted.channels
            while pending.count >= size {
                let frame = Data(pending.prefix(size)); pending = Data(pending.dropFirst(size)); try decode(frame)
            }
        }
    }
    private func decode(_ packet: Data) throws {
        let pcm: Data
        if isOgg == true {
            guard let oggDecoder else { throw PlaudAuthError.message("Ogg stream is missing OpusHead") }
            pcm = try oggDecoder.decode(packet)
        } else {
            guard let result = decoder.decode(packet, encrypted.channels), !result.isEmpty else {
                throw PlaudAuthError.message("Native fixed-frame Opus decoding failed (bytes \(packet.count), channels \(encrypted.channels))")
            }
            pcm = result
        }
        guard !pcm.isEmpty else { return }
        try file?.append(pcm); packets += 1
        // WorkScribe's speech input is signed 16-bit, 16 kHz mono.
        if encrypted.channels == 1 { onPCM?(pcm) }
        else {
            let samples = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            var mono = [Int16](); mono.reserveCapacity(samples.count / 2)
            for i in stride(from: 0, to: samples.count - 1, by: 2) { mono.append(Int16((Int32(samples[i]) + Int32(samples[i+1])) / 2)) }
            onPCM?(mono.withUnsafeBytes { Data($0) })
        }
        if Date().timeIntervalSince(lastReport) > 0.5 {
            lastReport = Date()
            onStatus?(Double(file?.bytes ?? 0) / Double(encrypted.channels * 32000), packets)
        }
    }
    func finishAndWait() async {
        await withCheckedContinuation { continuation in queue.async { [self] in finishOnQueue(); continuation.resume() } }
    }
    func finish() { queue.async { [self] in finishOnQueue() } }
    private func finishOnQueue() {
        guard !closed else { return }; closed = true
        do { try file?.close() } catch { onError?("Couldn’t finalize audio: \(error.localizedDescription)") }
        try? compressedFile?.close(); compressedFile = nil
        decoder.releaseDecoder()
        onStatus?(Double(file?.bytes ?? 0) / Double(encrypted.channels * 32000), packets)
    }
}
