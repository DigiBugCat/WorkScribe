// Ported from DigUp (MIT, © 2026 Abdur Rahim), Sources/DigUpKit/Platform/Apple/Extractors+Apple.swift and
// Media+Apple.swift @ f9b8106. See Resources/licenses/digup. Changes: Float32 10 s windows for EmbeddingGemma 2's
// Core ML audio encoder (DigUp wrote 30 s Int16 WAVs for llama.cpp), image text through Vision OCR.
// The indexer also embeds image pixels through EmbeddingGemmaVision when its optional assets are installed.
import AppKit
@preconcurrency import AVFoundation
import Foundation
import PDFKit
import Vision
import WorkScribeCore

struct FileExtractors: FileExtracting {
    /// A PDF page with less text than this is a scan or a slide; DigUp embedded its picture. Without a vision tower
    /// its words come from OCR instead.
    static let minimumPageText = 200

    func passages(of url: URL, kind: ChunkKind) async throws -> (title: String?, passages: [Passage]) {
        switch kind {
        case .image:
            let text = Self.recognizedText(in: url)
            return (nil, text.isEmpty ? [] : [Passage(text: text)])
        case .document:
            let ext = url.pathExtension.lowercased()
            if ext == "pdf" { return try Self.pdf(url) }
            if ["docx", "doc", "odt", "rtf"].contains(ext) {
                let type: NSAttributedString.DocumentType = switch ext {
                case "docx": .officeOpenXML
                case "doc": .docFormat
                case "odt": .openDocument
                default: .rtf
                }
                let text = try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil).string
                return (nil, text.components(separatedBy: "\n\n").map { Passage(text: $0) })
            }
            return try await PlainTextExtractor().passages(of: url, kind: kind)
        default:
            return (nil, [])
        }
    }

    /// One passage per PDF page (pages are what a link opens to). Long pages are split, keeping their page number.
    static func pdf(_ url: URL) throws -> (title: String?, passages: [Passage]) {
        guard let document = PDFDocument(url: url) else { throw FolderIndexer.Skip.unsupported("pdf (unreadable)") }
        if document.isLocked { throw FolderIndexer.Skip.unsupported("pdf (password-protected)") }
        var passages: [Passage] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count < minimumPageText, let image = render(page, pixels: 2000) {
                let read = ocr(image)
                if read.count > text.count { text = read }
            }
            for piece in text.components(separatedBy: "\n\n") { passages.append(Passage(text: piece, page: index + 1)) }
        }
        return (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, passages)
    }

    static func render(_ page: PDFPage, pixels: Int) -> CGImage? {
        let side = CGFloat(pixels)
        return page.thumbnail(of: NSSize(width: side, height: side), for: .mediaBox)
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    static func recognizedText(in url: URL) -> String {
        guard NoteImageContent.isMaterialized(url), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary) else { return "" }
        return ocr(image)
    }

    /// Apple Vision, accurate level: small UI text is what screenshots are full of.
    static func ocr(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// Decodes a file's audio (a video's soundtrack) to 16 kHz mono Float32 and hands over consecutive 10 s windows.
    /// Streams: memory stays at one window, even for a 3-hour recording. A tail under 0.5 s is dropped, as FluidUse does.
    /// Video files still index their soundtrack; image-file vision support is a separate path.
    func audioWindows(of url: URL, _ body: (AudioWindow) async throws -> Void) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw FolderIndexer.Skip.empty }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Double(Embedders.audioSampleRate), AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? FolderIndexer.Skip.empty }
        defer { reader.cancelReading() }
        let window = Embedders.audioWindowSamples, rate = Double(Embedders.audioSampleRate)
        var buffer: [Float] = []
        var offset = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / 4)
            _ = chunk.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            buffer.append(contentsOf: chunk)
            while buffer.count >= window {
                try await body(AudioWindow(start: Double(offset) / rate, end: Double(offset + window) / rate,
                                           samples: Array(buffer[0..<window])))
                buffer.removeFirst(window)
                offset += window
            }
        }
        if reader.status == .failed { throw reader.error ?? FolderIndexer.Skip.empty }
        if buffer.count >= Embedders.audioSampleRate / 2 || (offset == 0 && !buffer.isEmpty) {
            try await body(AudioWindow(start: Double(offset) / rate, end: Double(offset + buffer.count) / rate, samples: buffer))
        }
    }
}
