import Foundation
import COpus

/// The SDK's JXAvcDecoder accepts only fixed 80-byte-per-channel packets.
/// Ogg carries packet boundaries and can use variable-bitrate Opus instead.
/// Use the same SDK's exported libopus implementation for those packets.
final class OpusPacketDecoder {
    let channels: Int
    private var decoder: OpaquePointer?
    private var multistream: OpaquePointer?
    private var skipFrames: Int
    init(header: Data, expectedChannels: Int) throws {
        guard header.count >= 19, header.prefix(8) == Data("OpusHead".utf8),
              header[8] <= 15, Int(header[9]) == expectedChannels,
              (1...2).contains(expectedChannels) else {
            throw PlaudAuthError.message("Unsupported Ogg Opus header")
        }
        channels = expectedChannels
        skipFrames = (Int(header[10]) | Int(header[11]) << 8) / 3 // 48 kHz units -> 16 kHz output
        var error: Int32 = 0
        if header[18] == 0 {
            decoder = opus_decoder_create(16000, Int32(channels), &error)
        } else {
            guard (header[18] == 1 || header[18] == 255), header.count >= 21 + channels else {
                throw PlaudAuthError.message("Unsupported Opus channel mapping")
            }
            let mapping = Array(header[21..<(21 + channels)])
            multistream = mapping.withUnsafeBufferPointer {
                opus_multistream_decoder_create(16000, Int32(channels), Int32(header[19]), Int32(header[20]), $0.baseAddress, &error)
            }
        }
        guard error == 0, decoder != nil || multistream != nil else {
            throw PlaudAuthError.message("Native Opus initialization failed (\(error))")
        }
    }
    deinit {
        if let decoder { opus_decoder_destroy(decoder) }
        if let multistream { opus_multistream_decoder_destroy(multistream) }
    }
    func decode(_ packet: Data) throws -> Data {
        guard !packet.isEmpty, packet.count <= 1024 * 1024 else { throw PlaudAuthError.message("Invalid Opus packet size") }
        var pcm = [Int16](repeating: 0, count: 1920 * channels) // Opus maximum: 120 ms
        let frames: Int32 = packet.withUnsafeBytes { raw in
            let input = raw.bindMemory(to: UInt8.self).baseAddress!
            if let decoder { return opus_decode(decoder, input, Int32(packet.count), &pcm, 1920, 0) }
            return opus_multistream_decode(multistream!, input, Int32(packet.count), &pcm, 1920, 0)
        }
        guard frames >= 0 else { throw PlaudAuthError.message("Native Opus packet rejected (code \(frames), bytes \(packet.count))") }
        let skip = min(skipFrames, Int(frames)); skipFrames -= skip
        return pcm.withUnsafeBytes { Data($0[(skip * channels * 2)..<(Int(frames) * channels * 2)]) }
    }
}
