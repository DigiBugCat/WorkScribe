import Foundation

@main struct DecodeOgg {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3 else { throw PlaudAuthError.message("Usage: decode-ogg input output.wav") }
        var framing = OggPackets()
        let packets = try framing.append(Data(contentsOf: URL(fileURLWithPath: args[1])))
        guard let header = packets.first, header.prefix(8) == Data("OpusHead".utf8) else {
            throw PlaudAuthError.message("Missing Opus header")
        }
        let channels = Int(header[9])
        let decoder = try OpusPacketDecoder(header: header, expectedChannels: channels)
        let file = try PCMFile(url: URL(fileURLWithPath: args[2]), channels: channels)
        var count = 0
        for packet in packets.dropFirst() where packet.prefix(8) != Data("OpusTags".utf8) {
            try file.append(decoder.decode(packet)); count += 1
        }
        try file.close()
        print("Decoded \(count) audio packets; \(Double(file.bytes) / Double(channels * 32000)) seconds, \(channels) channel(s)")
    }
}
