@preconcurrency import CoreML
import CoreGraphics
import Foundation
import ImageIO
import WorkScribeCore

/// FluidInference's pinned vision_70 graph. The existing FluidUse revision has no Swift image
/// wrapper, so preprocessing and the four-token image envelope are implemented here from config.json.
/// 70 soft tokens keep background retrieval bounded; OCR remains separate for exact screenshot text.
actor EmbeddingGemmaVision {
    let directory: URL
    private var vision: MLModel?
    private var text: MLModel?
    private var positions: Data?
    private var table: Data?
    init(directory: URL) { self.directory = directory }
    static func available(in directory: URL) -> Bool {
        ["EmbeddingGemma2Vision.mlmodelc", "position_embeddings.f16"].allSatisfy {
            RuntimeAssets.inspect(directory.appendingPathComponent($0)) == .present
        }
    }
    func release() { vision = nil; text = nil; positions = nil; table = nil }
    func embed(_ url: URL) async throws -> [Float] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary) else { throw EmbedderError.badVector("unreadable image") }
        return try await embed(image)
    }
    func embed(_ image: CGImage) async throws -> [Float] {
        if vision == nil {
            for file in ["EmbeddingGemma2Vision.mlmodelc", "EmbeddingGemma2Text.mlmodelc", "position_embeddings.f16", "embeddings.bf16"] {
                try RuntimeAssets.require(directory.appendingPathComponent(file))
            }
            let config = MLModelConfiguration(); config.computeUnits = .cpuAndGPU; config.functionName = "vision_70"
            let loadedVision = try await MLModel.load(contentsOf: directory.appendingPathComponent("EmbeddingGemma2Vision.mlmodelc"), configuration: config)
            let t = MLModelConfiguration(); t.computeUnits = .cpuAndNeuralEngine; t.functionName = "embed_128"
            let loadedText = try await MLModel.load(contentsOf: directory.appendingPathComponent("EmbeddingGemma2Text.mlmodelc"), configuration: t)
            let loadedPositions = try Data(contentsOf: directory.appendingPathComponent("position_embeddings.f16"), options: .mappedIfSafe)
            let loadedTable = try Data(contentsOf: directory.appendingPathComponent("embeddings.bf16"), options: .mappedIfSafe)
            guard loadedPositions.count == 2 * 1024 * 768 * 2, loadedTable.count == 262144 * 512 * 2 else { throw EmbedderError.badVector("image tables") }
            vision = loadedVision; text = loadedText; positions = loadedPositions; table = loadedTable
        }
        let (input, count) = try Self.preprocess(image, positions: positions!)
        let output = try await vision!.prediction(from: input)
        guard let tokens = output.featureValue(for: "image_tokens")?.multiArrayValue else { throw EmbedderError.badVector("image tokens") }
        let embeds = try MLMultiArray(shape: [1,128,512], dataType: .float16)
        let mask = try MLMultiArray(shape: [1,128], dataType: .float16)
        let dest = embeds.dataPointer.assumingMemoryBound(to: Float16.self)
        dest.initialize(repeating: 0, count: embeds.count)
        func word(_ id: Int, at row: Int) {
            table!.withUnsafeBytes { raw in
                let source = raw.bindMemory(to: UInt16.self)
                for c in 0..<512 { dest[row * 512 + c] = Float16(Float(bitPattern: UInt32(source[id * 512 + c]) << 16) * sqrt(512)) }
            }
        }
        word(2, at: 0); word(255999, at: 1)
        for r in 0..<count { for c in 0..<512 {
            dest[(r+2)*512+c] = Float16(tokens[[0, NSNumber(value: r), NSNumber(value: c)]].floatValue)
        } }
        word(258882, at: count+2); word(1, at: count+3)
        for i in 0..<128 { mask[i] = NSNumber(value: i < count+4 ? 1 : 0) }
        let result = try await text!.prediction(from: MLDictionaryFeatureProvider(dictionary: ["inputs_embeds": embeds, "attention_mask": mask]))
        guard let values = result.featureValue(for: "embedding")?.multiArrayValue,
              let vector = VectorMath.normalized((0..<values.count).map { values[$0].floatValue }), vector.count == 768 else { throw EmbedderError.badVector("image embedding") }
        return vector
    }
    static func preprocess(_ image: CGImage, positions: Data) throws -> (MLFeatureProvider, Int) {
        // Area-preserving fit; at least one 3x3 patch group per dimension, at most 70 groups.
        let ratio = Double(image.width) / Double(image.height)
        var gx = max(1, Int(sqrt(70 * ratio))), gy = max(1, Int(sqrt(70 / ratio)))
        gx = min(gx, 70); gy = min(gy, 70)
        while gx * gy > 70 { if gx > gy { gx -= 1 } else { gy -= 1 } }
        let width = gx * 48, height = gy * 48, cols = gx * 3, rows = gy * 3
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
        }
        guard drawn else { throw EmbedderError.badVector("image resize") }
        func array(_ shape: [NSNumber], _ type: MLMultiArrayDataType = .float16) throws -> MLMultiArray {
            let value = try MLMultiArray(shape: shape, dataType: type)
            memset(value.dataPointer, 0, value.count * (type == .float16 ? 2 : 4)); return value
        }
        let patches = try array([1,630,768]), pos = try array([1,630,2]), positional = try array([1,630,768]), valid = try array([1,630]), pool = try array([70,630])
        let pp = patches.dataPointer.assumingMemoryBound(to: Float16.self), ep = positional.dataPointer.assumingMemoryBound(to: Float16.self)
        let xy = pos.dataPointer.assumingMemoryBound(to: Float16.self), vp = valid.dataPointer.assumingMemoryBound(to: Float16.self), gp = pool.dataPointer.assumingMemoryBound(to: Float16.self)
        for i in 0..<1260 { xy[i] = -1 }
        positions.withUnsafeBytes { raw in
            let table = raw.bindMemory(to: Float16.self)
            for y in 0..<rows { for x in 0..<cols {
                let n = y * cols + x; xy[n*2] = Float16(x); xy[n*2+1] = Float16(y); vp[n] = 1
                gp[((y/3)*gx+x/3)*630+n] = Float16(1.0/9.0)
                for py in 0..<16 { for px in 0..<16 { for c in 0..<3 {
                    pp[n*768+(py*16+px)*3+c] = Float16(Float(pixels[((y*16+py)*width+x*16+px)*4+c])/255)
                } } }
                for c in 0..<768 { ep[n*768+c] = table[x*768+c] + table[(1024+y)*768+c] }
            } }
        }
        return (try MLDictionaryFeatureProvider(dictionary: ["patches": patches, "positions": pos, "position_embeddings": positional, "valid": valid, "pool": pool]), gx*gy)
    }
}
