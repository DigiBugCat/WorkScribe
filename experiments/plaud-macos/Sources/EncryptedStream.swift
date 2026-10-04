import Foundation
import PlaudBleSDK
import PlaudDeviceBasicSDK

struct AudioPacket {
    let offset: Int
    let bytes: Data
}

/// Reassembles the SDK's ordered file stream and decrypts its audio payload.
/// Ownership and key authorization happen before this decoder is constructed.
final class EncryptedStream {
    private let privateKey: String
    private var prefix = Data()
    private var header: PlaudEncryptHeader?
    private var key: Data?
    private(set) var expectedOffset = 0
    var channels: Int { Int(header?.channel ?? 1) }
    init(privateKey: String) { self.privateKey = privateKey }

    func accept(offset: Int, bytes: Data) throws -> [AudioPacket] {
        guard offset >= 0, bytes.count <= 1024 * 1024, offset <= Int.max - bytes.count else {
            throw PlaudAuthError.message("Invalid audio packet range")
        }
        guard offset <= expectedOffset else { throw PlaudAuthError.message("Audio packet gap; resync is required") }
        let duplicate = expectedOffset - offset
        if duplicate >= bytes.count { return [] }
        var remaining = Data(bytes.dropFirst(duplicate))
        var currentOffset = expectedOffset
        if header == nil {
            let needed = PlaudEncryptHeader.headerSize - prefix.count
            let count = min(needed, remaining.count)
            prefix.append(remaining.prefix(count)); remaining = Data(remaining.dropFirst(count)); currentOffset += count
            if prefix.count == PlaudEncryptHeader.headerSize {
                guard let parsed = PlaudEncryptHeader(data: prefix), parsed.headerSizeValue == PlaudEncryptHeader.headerSize,
                      (1...2).contains(Int(parsed.channel)) else {
                    throw PlaudAuthError.message("Unsupported Plaud audio header")
                }
                if parsed.isEncrypted {
                    let unwrapped = try SecretUtil.decryptWithPrivateKey(parsed.keyCipher, privateKeyPem: privateKey)
                    guard unwrapped.count == 32, parsed.nonce.count == 12 else {
                        throw PlaudAuthError.message("Unsupported Plaud audio encryption parameters")
                    }
                    key = unwrapped
                }
                header = parsed; prefix = Data()
            }
        }
        expectedOffset = offset + bytes.count
        guard let header, !remaining.isEmpty else { return [] }
        let audioOffset = currentOffset - Int(header.headerSizeValue)
        let decoded: Data
        if let key {
            decoded = try Self.decrypt(remaining, audioOffset: audioOffset, key: key,
                                       nonce: header.nonce, segment: Int(header.segment))
        } else { decoded = remaining }
        return [AudioPacket(offset: audioOffset, bytes: decoded)]
    }

    /// Mirrors the SDK's decryptAligned rule: 64-byte ChaCha blocks, with a
    /// counter reset at each configured segment. Split boundary-crossing reads.
    static func decrypt(_ data: Data, audioOffset: Int, key: Data, nonce: Data, segment: Int) throws -> Data {
        guard audioOffset >= 0, key.count == 32, nonce.count == 12, segment >= 0 else {
            throw PlaudAuthError.message("Invalid stream decryption parameters")
        }
        var output = Data(), consumed = 0
        while consumed < data.count {
            let absolute = audioOffset + consumed
            let relative = segment > 0 ? absolute % segment : absolute
            let count = min(data.count - consumed, segment > 0 ? segment - relative : data.count - consumed)
            let block = relative / 64, skip = relative % 64
            guard block <= Int(UInt32.max) else { throw PlaudAuthError.message("Audio stream exceeds cipher range") }
            var aligned = Data(repeating: 0, count: skip)
            aligned.append(data.dropFirst(consumed).prefix(count))
            let plaintext = try ChaCha20.decrypt(data: aligned, key: key, nonce: nonce, counter: UInt32(block))
            output.append(plaintext.dropFirst(skip)); consumed += count
        }
        return output
    }
}
