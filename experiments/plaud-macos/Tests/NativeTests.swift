import Foundation
import PlaudBleSDK
import PlaudDeviceBasicSDK

struct TestFailure: Error { let message: String }
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(message: message) }
}
func metadataPage(sequence: UInt32, continued: Bool, bytes: Int) -> Data {
    var page = Data("OggS".utf8)
    page.append(contentsOf: [0, continued ? 1 : 2])
    page.append(Data(repeating: 0, count: 8))
    for value in [UInt32(0x12345678), sequence, UInt32(0)] {
        var little = value.littleEndian; page.append(Data(bytes: &little, count: 4))
    }
    page.append(1); page.append(UInt8(bytes)); page.append(Data(repeating: 17, count: bytes))
    var crc: UInt32 = 0
    for byte in page {
        crc ^= UInt32(byte) << 24
        for _ in 0..<8 { crc = crc & 0x80000000 != 0 ? (crc << 1) ^ 0x04c11db7 : crc << 1 }
    }
    var little = crc.littleEndian
    page.replaceSubrange(22..<26, with: Data(bytes: &little, count: 4))
    return page
}
actor MockPlaudServer {
    var paths: [String] = []
    var reject = false
    var ownership: Bool? = false
    var omitOwnership = false
    func setReject() { reject = true }
    func setOwnership(_ value: Bool?, omit: Bool = false) { ownership = value; omitOwnership = omit }
    func respond(_ request: URLRequest) throws -> (Data, Int) {
        paths.append(request.url!.path)
        if reject { return (Data("{\"private\":\"must not appear in errors\"}".utf8), 403) }
        let path = request.url!.path
        let result: [String: Any]
        if path.hasSuffix("oauth/partner/access-token") {
            try check(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("client:test-secret".utf8).base64EncodedString(), "basic authentication")
            result = ["access_token": "partner-token"]
        } else if path.hasSuffix("users/access-token") {
            try check(request.value(forHTTPHeaderField: "Authorization") == "Bearer partner-token", "user token authorization")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            try check(body["user_id"] as? String == "test-user", "stable user ID")
            let claims = Data("{\"sub\":\"device-owner\"}".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
            result = ["access_token": "header.\(claims).signature", "expires_in": 86400]
        } else if path.hasSuffix("sdk/binding") {
            try check(request.httpMethod == "GET", "read-only ownership check")
            result = omitOwnership ? [:] : ["is_bind": ownership.map { $0 as Any } ?? NSNull()]
        } else if path.hasSuffix("sdk/gen-key") {
            result = ["data": ["public_key": "public", "private_key": "private"]]
        } else if path.hasSuffix("sdk/sn-sign") {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            try check(body["type"] as? String == "notepro", "Note Pro type")
            try check(body["sn"] as? String == "881-test", "target device")
            result = ["signature": "authorized-signature"]
        } else { throw TestFailure(message: "unexpected endpoint") }
        return (try JSONSerialization.data(withJSONObject: result), 200)
    }
}
@main struct NativeTests {
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("TEST FAILURE: \(error)\n".utf8)); exit(1) }
    }
    static func stage(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
    static func run() async throws {
        stage("auth tests starting")
        let server = MockPlaudServer()
        let auth = PlaudAuth(transport: { try await server.respond($0) })
        let session = try await auth.authenticate(clientID: "client", secret: "test-secret", userID: "test-user")
        try check(session.subject == "device-owner", "subject mapping")
        let handshake = try await auth.prepare(session: session, serial: "881-test")
        try check(handshake.signature == "authorized-signature", "server-issued signature")
        let paths = await server.paths
        try check(paths.count == 4, "exact authentication sequence")
        try check(!paths.contains(where: { $0.hasSuffix("/bind") }), "preparation must not bind the device")
        try check(!paths.contains(where: { $0.hasSuffix("/binding") }), "normal reconnect must not use the recovery-only binding gate")
        await server.setReject()
        do {
            _ = try await auth.authenticate(clientID: "client", secret: "test-secret", userID: "test-user")
            throw TestFailure(message: "403 accepted")
        } catch let error as PlaudAuthError {
            try check(!error.localizedDescription.contains("must not appear"), "server body redaction")
        }
        try check(PlaudAuth.subject("not-a-token") == nil, "malformed token")

        stage("native crypto tests starting")
        let rsa = try SwiftyRSA.generateRSAKeyPair(sizeInBits: 2048)
        let privatePEM = try rsa.privateKey.pemString()
        let publicPEM = try rsa.publicKey.pemString()
        let importedPrivate = try PrivateKey(pemEncoded: privatePEM)
        let importedPublic = try PublicKey(pemEncoded: publicPEM)
        let clearRSA = ClearMessage(data: Data("native RSA round trip".utf8))
        let encryptedRSA = try clearRSA.encrypted(with: importedPublic, padding: .PKCS1)
        let decryptedRSA = try encryptedRSA.decrypted(with: importedPrivate, padding: .PKCS1)
        try check(decryptedRSA.data == clearRSA.data, "native RSA PEM round trip")
        let payload = Data("local authenticated audio test".utf8)
        let key = Data(repeating: 7, count: 32), nonce = Data(repeating: 3, count: 12)
        let encrypted = try SecretUtil.encryptWithChaChaPoly1305Separate(payload, key: key, nonce: nonce)
        let decoded = try SecretUtil.decryptWithChaChaPoly1305Separate(encrypted.ciphertext, tag: encrypted.tag, key: key, nonce: nonce)
        try check(decoded == payload, "native SDK crypto round trip")
        var corrupt = encrypted.tag; corrupt[corrupt.startIndex] ^= 1
        do {
            _ = try SecretUtil.decryptWithChaChaPoly1305Separate(encrypted.ciphertext, tag: corrupt, key: key, nonce: nonce)
            throw TestFailure(message: "tampered data accepted")
        } catch is TestFailure { throw TestFailure(message: "tampered data accepted") }
        catch { }
        try check(ChaCha20.verifyRFC7539TestVector(), "SDK RFC 7539 vector")
        try check(PlaudEncryptHeader.headerSize == 512, "SDK header size")
        try check(PlaudEncryptHeader(data: Data(repeating: 0, count: 64)) == nil, "truncated header")
        let original = Data((0..<513).map { UInt8($0 % 251) })
        for segment in [0, 128] {
            let cipher = try EncryptedStream.decrypt(original, audioOffset: 0, key: key, nonce: nonce, segment: segment)
            var recovered = Data()
            for start in stride(from: 0, to: original.count, by: 37) {
                let chunk = Data(cipher.dropFirst(start).prefix(37))
                recovered.append(try EncryptedStream.decrypt(chunk, audioOffset: start, key: key, nonce: nonce, segment: segment))
            }
            try check(recovered == original, "unaligned and segment-boundary decryption")
        }
        if CommandLine.arguments.count > 1 {
            let ogg = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let reference = OggOpusParser().parse(ogg)
            var multiplexed = metadataPage(sequence: 0, continued: false, bytes: 255)
            // Leave the metadata packet open while the audio stream completes.
            multiplexed.append(ogg)
            multiplexed.append(metadataPage(sequence: 1, continued: true, bytes: 45))
            var demux = OggPackets()
            let demuxed = try demux.append(multiplexed).filter {
                $0.prefix(8) != Data("OpusHead".utf8) && $0.prefix(8) != Data("OpusTags".utf8)
            }
            try check(demuxed == reference, "interleaved metadata must never enter the audio decoder")
            for size in [1, 37, 4096] {
                var framer = OggPackets(), frames: [Data] = []
                for start in stride(from: 0, to: ogg.count, by: size) {
                    frames += try framer.append(Data(ogg.dropFirst(start).prefix(size)))
                }
                frames = frames.filter { $0.prefix(8) != Data("OpusHead".utf8) && $0.prefix(8) != Data("OpusTags".utf8) }
                try check(frames == reference, "incremental Ogg framing at chunk size \(size)")
            }
            var corrupt = ogg; corrupt[corrupt.count - 1] ^= 1
            do { var framer = OggPackets(); _ = try framer.append(corrupt); throw TestFailure(message: "Ogg corruption accepted") }
            catch is PlaudAuthError { }
            var framer = OggPackets()
            let allPackets = try framer.append(ogg)
            let header = allPackets.first { $0.prefix(8) == Data("OpusHead".utf8) }!
            let channels = Int(header[9])
            let decoder = try OpusPacketDecoder(header: header, expectedChannels: channels)
            var bytes = 0
            for packet in reference { bytes += try decoder.decode(packet).count }
            try check(bytes > 0, "native variable-packet Opus decoding")
            if CommandLine.arguments.count > 2 {
                try check(reference.contains { $0.count != 80 * channels }, "fixture must exercise non-fixed Opus packet sizes")
            }
        }
        print("PASS: authentication sequence, authenticated reconnect sequence, no premature binding, error redaction, JWT parsing, native RSA PEM round trip, native SDK authenticated encryption, tamper rejection, aligned decryption, Ogg framing and Opus decoding")
    }
}
