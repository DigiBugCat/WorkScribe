import Accelerate
import Darwin
import Foundation

/// Storage is a rebuildable accelerator. SQLite owns full vectors, chunk identity and metadata.
public protocol VectorStore: AnyObject, Sendable {
    func upsert(_ records: [VectorRecord]) throws
    func delete(ids: [Int64]) throws
    func search(query: [Float], k: Int, filter: VectorFilter) throws -> VectorSearch
    func compact() throws
    func withExclusiveAccess<T>(_ body: () throws -> T) throws -> T
    func reset() throws
    func setNamespace(_ value: UInt64) throws
    func persist(checkpoint: Int64) throws
    var stats: VectorStoreStats { get throws }
}

public struct VectorRecord: Sendable {
    public var id: Int64
    public var sourceID: Int64
    public var kind: ChunkKind
    public var modality: Modality
    /// Absolute seconds since 1970, or nil when the source has no date.
    public var time: Double?
    public var endTime: Double?
    public var vector: [Float]
    public init(id: Int64, sourceID: Int64, kind: ChunkKind, modality: Modality = .text,
                time: Double? = nil, endTime: Double? = nil, vector: [Float]) {
        self.id = id; self.sourceID = sourceID; self.kind = kind; self.modality = modality
        self.time = time; self.endTime = endTime; self.vector = vector
    }
}

public struct VectorFilter: Sendable {
    public var kinds: Set<ChunkKind>?
    /// A meeting filter is its source ID. An empty set matches nothing.
    public var sources: Set<Int64>?
    /// Inclusive interval overlap. Undated vectors do not match a time filter.
    public var timeRange: ClosedRange<Double>?
    public init(kinds: Set<ChunkKind>? = nil, sources: Set<Int64>? = nil, timeRange: ClosedRange<Double>? = nil) {
        self.kinds = kinds; self.sources = sources; self.timeRange = timeRange
    }
}

public struct VectorMatch: Sendable {
    public var id: Int64
    public var score: Float
    public init(id: Int64, score: Float) { self.id = id; self.score = score }
}
public struct VectorSearch: Sendable {
    public var matches: [VectorMatch]
    public var population: Int
    public init(matches: [VectorMatch], population: Int) { self.matches = matches; self.population = population }
}
public struct VectorStoreStats: Sendable {
    public var count: Int
    public var tombstones: Int
    public var mappedBytes: Int
    public var checkpoint: Int64
    public init(count: Int, tombstones: Int, mappedBytes: Int, checkpoint: Int64) {
        self.count = count; self.tombstones = tombstones; self.mappedBytes = mappedBytes; self.checkpoint = checkpoint
    }
}

public enum VectorEncoding {
    public static let dimension = 256
    public static func truncated(_ vector: [Float]) throws -> [Float] {
        guard let unit = VectorMath.normalized(Array(vector.prefix(dimension))), vector.allSatisfy(\.isFinite) else {
            throw EmbedderError.badVector("zero or non-finite Matryoshka prefix")
        }
        return unit + Array(repeating: 0, count: dimension - unit.count)
    }
    public static func quantize(_ vector: [Float]) throws -> (values: [Int8], scale: Float) {
        let unit = try truncated(vector)
        let scale = unit.map(abs).max()! / 127
        return (unit.map { Int8(max(-127, min(127, ($0 / scale).rounded()))) }, scale)
    }
    /// Full vectors use IEEE float16, little-endian. Dimension is stored separately in SQLite.
    public static func fullBlob(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * 2)
        for value in vector { var bits = Float16(value).bitPattern.littleEndian; withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) } }
        return data
    }
    public static func fullVector(_ data: Data, dimension: Int, legacy: Bool = false) -> [Float]? {
        guard dimension > 0, data.count == dimension * (legacy ? 4 : 2) else { return nil }
        return data.withUnsafeBytes { bytes in
            (0..<dimension).map { i in
                legacy ? Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)))
                : Float(Float16(bitPattern: UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))))
            }
        }
    }
}

/// Bounded top-k min heap; tie order is stable across parallel partitions.
struct VectorHeap {
    var values: [VectorMatch] = []
    let capacity: Int
    static func worse(_ a: VectorMatch, _ b: VectorMatch) -> Bool {
        a.score < b.score || (a.score == b.score && a.id > b.id)
    }
    mutating func add(_ item: VectorMatch) {
        guard capacity > 0 else { return }
        if values.count < capacity {
            values.append(item)
            var i = values.count - 1
            while i > 0 {
                let parent = (i - 1) / 2
                if !Self.worse(values[i], values[parent]) { break }
                values.swapAt(i, parent); i = parent
            }
        } else if Self.worse(values[0], item) {
            values[0] = item
            var i = 0
            while i * 2 + 1 < values.count {
                var child = i * 2 + 1
                if child + 1 < values.count && Self.worse(values[child + 1], values[child]) { child += 1 }
                if !Self.worse(values[child], values[i]) { break }
                values.swapAt(child, i); i = child
            }
        }
    }
    var sorted: [VectorMatch] { values.sorted { Self.worse($1, $0) } }
}

/// Native Swift int8 scan, mmap-backed fixed records. File format v1: 64-byte header, 320-byte records;
/// [id:i64, source:i64, time:f64, end:f64, kind:u8, modality:u8, dimension:u16, scale:f32,
/// alive:u8, reserved:23, vector:i8x256]. Mutations are serialized with flock across app/MCP processes.
/// No heap vector matrix; the id->slot dictionary is the only O(N) resident allocation.
public final class MappedVectorStore: VectorStore, @unchecked Sendable {
    public enum Kernel: String, Sendable { case simd, vdsp }
    public let url: URL
    public var kernel: Kernel
    public var workers: Int
    private let mutex = NSRecursiveLock()
    private let lockFD: Int32
    private var fd: Int32 = -1
    private var mapping: UnsafeMutableRawPointer?
    private var bytes = 0
    private var generation: UInt64 = .max
    private var slots: [Int64: Int] = [:]
    private static let header = 64, stride = 320
    private static let magic: UInt64 = 0x315645435357 // WSC EV1

    public init(url: URL, kernel: Kernel = .simd, workers: Int = 4) throws {
        self.url = url; self.kernel = kernel; self.workers = max(1, workers)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        lockFD = Darwin.open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0 else { throw Self.failure("open lock") }
        do {
            try withExclusiveAccess {
                if !FileManager.default.fileExists(atPath: url.path) {
                    var header = Data(count: Self.header)
                    header.put(Self.magic, at: 0)
                    try header.write(to: url, options: .atomic)
                    _ = chmod(url.path, 0o600)
                }
                try refresh(force: true)
            }
        } catch { Darwin.close(lockFD); throw error }
    }
    deinit { if let mapping { munmap(mapping, bytes) }; if fd >= 0 { Darwin.close(fd) }; Darwin.close(lockFD) }
    private static func failure(_ operation: String) -> Database.Failure {
        Database.Failure(message: "Vector store \(operation): \(String(cString: strerror(errno)))")
    }
    /// Holds one cross-process snapshot through SQLite reconciliation and search when called by SearchIndex.
    public func withExclusiveAccess<T>(_ body: () throws -> T) throws -> T {
        mutex.lock(); defer { mutex.unlock() }
        // Recursive calls share the outer flock (flock itself isn't recursive).
        if lockDepth > 0 { lockDepth += 1; defer { lockDepth -= 1 }; return try body() }
        guard flock(lockFD, LOCK_EX) == 0 else { throw Self.failure("lock") }
        lockDepth = 1
        defer { lockDepth = 0; flock(lockFD, LOCK_UN) }
        do { return try body() } catch { generation = .max; throw error }
    }
    private var lockDepth = 0
    private func refresh(force: Bool = false, rebuildIDs: Bool = true) throws {
        let newFD = Darwin.open(url.path, O_RDWR)
        guard newFD >= 0 else { throw Self.failure("open") }
        var stat = Darwin.stat()
        guard fstat(newFD, &stat) == 0 else { Darwin.close(newFD); throw Self.failure("stat") }
        var header = [UInt64](repeating: 0, count: 8)
        let got = header.withUnsafeMutableBytes { pread(newFD, $0.baseAddress, Self.header, 0) }
        guard got == Self.header, header[0] == Self.magic, stat.st_size >= Self.header,
              (Int(stat.st_size) - Self.header) % Self.stride == 0 else {
            Darwin.close(newFD); throw Database.Failure(message: "Invalid vector cache; remove it to rebuild from SQLite")
        }
        if !force, generation == header[1], bytes == stat.st_size { Darwin.close(newFD); return }
        if let mapping { munmap(mapping, bytes) }
        if fd >= 0 { Darwin.close(fd) }
        fd = newFD; bytes = Int(stat.st_size)
        mapping = mmap(nil, bytes, PROT_READ, MAP_SHARED, fd, 0)
        guard mapping != MAP_FAILED else { mapping = nil; throw Self.failure("mmap") }
        generation = header[1]
        guard rebuildIDs else { return }
        slots.removeAll(keepingCapacity: true)
        for slot in 0..<recordCount {
            let p = record(slot)
            if p.load(fromByteOffset: 40, as: UInt8.self) == 1 { slots[p.load(as: Int64.self)] = slot }
        }
    }
    private var recordCount: Int { (bytes - Self.header) / Self.stride }
    private func record(_ slot: Int) -> UnsafeRawPointer { UnsafeRawPointer(mapping!).advanced(by: Self.header + slot * Self.stride) }
    private func write(_ data: Data, offset: Int) throws {
        try data.withUnsafeBytes { ptr in
            var sent = 0
            while sent < data.count {
                let n = pwrite(fd, ptr.baseAddress!.advanced(by: sent), data.count - sent, off_t(offset + sent))
                guard n > 0 else { if errno == EINTR { continue }; throw Self.failure("write") }
                sent += n
            }
        }
    }
    private func changed() throws {
        var data = Data(count: 8); data.put(generation &+ 1, at: 0)
        try write(data, offset: 8)
        try refresh(force: true, rebuildIDs: false)
    }
    public var stats: VectorStoreStats {
        get throws { try withExclusiveAccess { try refresh(); return VectorStoreStats(count: slots.count, tombstones: recordCount - slots.count,
            mappedBytes: bytes, checkpoint: mapping!.load(fromByteOffset: 16, as: Int64.self)) } }
    }
    public func upsert(_ records: [VectorRecord]) throws {
        guard !records.isEmpty else { return }
        // Validate the entire batch before mutating anything.
        let encoded = try records.map { ($0, try VectorEncoding.quantize($0.vector)) }
        try withExclusiveAccess {
            try refresh()
            let firstSlot = recordCount
            var data = Data(count: records.count * Self.stride)
            var replaced = Set<Int64>()
            for (i, pair) in encoded.enumerated() {
                let (v, q) = pair, offset = i * Self.stride
                data.put(v.id, at: offset); data.put(v.sourceID, at: offset + 8)
                data.put(v.time ?? .nan, at: offset + 16); data.put(v.endTime ?? v.time ?? .nan, at: offset + 24)
                data[offset + 32] = UInt8(ChunkKind.allCases.firstIndex(of: v.kind)!)
                data[offset + 33] = UInt8(Modality.allCases.firstIndex(of: v.modality)!)
                data.put(UInt16(clamping: v.vector.count), at: offset + 34); data.put(q.scale, at: offset + 36)
                data[offset + 40] = 1
                data.replaceSubrange((offset + 64)..<(offset + 320), with: q.values.map { UInt8(bitPattern: $0) })
                if let old = slots[v.id], old < firstSlot { try write(Data([0]), offset: Self.header + old * Self.stride + 40) }
                slots[v.id] = firstSlot + i
                // A duplicate ID in one batch must also tombstone its earlier appended record.
                if !replaced.insert(v.id).inserted, let earlier = records[..<i].lastIndex(where: { $0.id == v.id }) {
                    data[earlier * Self.stride + 40] = 0
                }
            }
            try write(data, offset: bytes)
            try changed()
        }
    }
    public func delete(ids: [Int64]) throws {
        try withExclusiveAccess {
            try refresh()
            for id in ids { if let slot = slots.removeValue(forKey: id) { try write(Data([0]), offset: Self.header + slot * Self.stride + 40) } }
            if !ids.isEmpty { try changed() }
        }
    }
    public func persist(checkpoint: Int64) throws {
        try withExclusiveAccess {
            try refresh()
            // Flush record changes before publishing the journal checkpoint.
            guard fsync(fd) == 0 else { throw Self.failure("fsync") }
            var data = Data(count: 8); data.put(checkpoint, at: 0)
            try write(data, offset: 16)
            guard fsync(fd) == 0 else { throw Self.failure("checkpoint fsync") }
        }
    }
    /// Reset only derived data; keeps the cross-process lock inode.
    public func setNamespace(_ value: UInt64) throws {
        try withExclusiveAccess {
            try refresh()
            if mapping!.load(fromByteOffset: 24, as: UInt64.self) != value {
                try reset()
                var data = Data(count: 8); data.put(value, at: 0)
                try write(data, offset: 24)
                try changed()
            }
        }
    }
    public func reset() throws {
        try withExclusiveAccess {
            var header = Data(count: Self.header); header.put(Self.magic, at: 0)
            header.put(generation &+ 1, at: 8)
            if let mapping { header.put(mapping.load(fromByteOffset: 24, as: UInt64.self), at: 24) }
            let temp = url.appendingPathExtension(UUID().uuidString + ".tmp")
            try header.write(to: temp, options: .atomic)
            guard rename(temp.path, url.path) == 0 else { throw Self.failure("reset") }
            try refresh(force: true)
        }
    }
    static func recover(url: URL) throws -> MappedVectorStore {
        let lock = Darwin.open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw failure("recovery lock") }
        defer { flock(lock, LOCK_UN); Darwin.close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw failure("recovery lock") }
        var header = Data(count: Self.header); header.put(Self.magic, at: 0)
        try header.write(to: url, options: .atomic)
        // Constructor takes the lock itself; release first.
        flock(lock, LOCK_UN)
        return try MappedVectorStore(url: url)
    }
    public func compact() throws {
        try withExclusiveAccess {
            try refresh()
            let temporary = url.appendingPathExtension(UUID().uuidString + ".tmp")
            _ = FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let out = try FileHandle(forWritingTo: temporary)
            do {
                var header = Data(bytes: mapping!, count: Self.header); header.put(generation &+ 1, at: 8)
                try out.write(contentsOf: header)
                var buffer = Data(capacity: 4096 * Self.stride)
                for slot in 0..<recordCount where record(slot).load(fromByteOffset: 40, as: UInt8.self) == 1 {
                    buffer.append(record(slot).assumingMemoryBound(to: UInt8.self), count: Self.stride)
                    if buffer.count >= 4096 * Self.stride { try out.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
                }
                try out.write(contentsOf: buffer); try out.synchronize(); try out.close()
                guard rename(temporary.path, url.path) == 0 else { throw Self.failure("compact rename") }
                try refresh(force: true)
            } catch { try? out.close(); try? FileManager.default.removeItem(at: temporary); throw error }
        }
    }
    /// SIMD16 sign-extension and int32 accumulation: no saturation or int16 sum overflow.
    @inline(__always) static func int8Dot(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer) -> Int32 {
        var sum = SIMD16<Int32>(repeating: 0)
        for d in Swift.stride(from: 0, to: 256, by: 16) {
            let x = SIMD16<Int32>(truncatingIfNeeded: a.loadUnaligned(fromByteOffset: d, as: SIMD16<Int8>.self))
            let y = SIMD16<Int32>(truncatingIfNeeded: b.loadUnaligned(fromByteOffset: d, as: SIMD16<Int8>.self))
            sum = sum &+ (x &* y)
        }
        return sum.wrappedSum()
    }
    public func search(query: [Float], k: Int, filter: VectorFilter = VectorFilter()) throws -> VectorSearch {
        let q = try VectorEncoding.quantize(query)
        return try withExclusiveAccess {
            try refresh()
            let threads = min(workers, max(1, recordCount / 8192))
            let results = ScanResults(count: threads)
            let queryFloats = q.values.map(Float.init)
            let kindCodes = filter.kinds.map { Set($0.map { UInt8(ChunkKind.allCases.firstIndex(of: $0)!) }) }
            q.values.withUnsafeBytes { queryBytes in
                DispatchQueue.concurrentPerform(iterations: threads) { worker in
                    var heap = VectorHeap(capacity: max(0, k)), count = 0
                    let selectedKernel = kernel
                    let blockSize = 128
                    var block = [Float](repeating: 0, count: selectedKernel == .vdsp ? blockSize * 256 : 0)
                    var blockScores = [Float](repeating: 0, count: selectedKernel == .vdsp ? blockSize : 0)
                    var blockSlots: [Int] = []
                    func flushBlock() {
                        guard !blockSlots.isEmpty else { return }
                        vDSP_mmul(block, 1, queryFloats, 1, &blockScores, 1, vDSP_Length(blockSlots.count), 1, 256)
                        for (row, slot) in blockSlots.enumerated() {
                            let p = record(slot)
                            heap.add(VectorMatch(id: p.load(as: Int64.self),
                                score: blockScores[row] * p.load(fromByteOffset: 36, as: Float.self) * q.scale))
                        }
                        blockSlots.removeAll(keepingCapacity: true)
                    }
                    for slot in (recordCount * worker / threads)..<(recordCount * (worker + 1) / threads) {
                        let p = record(slot)
                        guard p.load(fromByteOffset: 40, as: UInt8.self) == 1,
                              Int(p.load(fromByteOffset: 34, as: UInt16.self)) == query.count else { continue }
                        if let kinds = kindCodes, !kinds.contains(p.load(fromByteOffset: 32, as: UInt8.self)) { continue }
                        if let sources = filter.sources, !sources.contains(p.load(fromByteOffset: 8, as: Int64.self)) { continue }
                        if let range = filter.timeRange {
                            let start = p.load(fromByteOffset: 16, as: Double.self), end = p.load(fromByteOffset: 24, as: Double.self)
                            guard start.isFinite, end >= range.lowerBound, start <= range.upperBound else { continue }
                        }
                        count += 1
                        if selectedKernel == .simd {
                            let score = Float(Self.int8Dot(p.advanced(by: 64), queryBytes.baseAddress!))
                                * p.load(fromByteOffset: 36, as: Float.self) * q.scale
                            heap.add(VectorMatch(id: p.load(as: Int64.self), score: score))
                        } else {
                            block.withUnsafeMutableBufferPointer { out in
                                vDSP_vflt8(p.advanced(by: 64).assumingMemoryBound(to: Int8.self), 1,
                                           out.baseAddress!.advanced(by: blockSlots.count * 256), 1, 256)
                            }
                            blockSlots.append(slot)
                            if blockSlots.count == blockSize { flushBlock() }
                        }
                    }
                    flushBlock()
                    results.set(worker, heap.values, count)
                }
            }
            var heap = VectorHeap(capacity: max(0, k))
            for list in results.hits { for hit in list { heap.add(hit) } }
            return VectorSearch(matches: heap.sorted, population: results.counts.reduce(0, +))
        }
    }
}

private final class ScanResults: @unchecked Sendable {
    private let lock = NSLock()
    var hits: [[VectorMatch]]
    var counts: [Int]
    init(count: Int) { hits = Array(repeating: [], count: count); counts = Array(repeating: 0, count: count) }
    func set(_ i: Int, _ values: [VectorMatch], _ count: Int) { lock.lock(); defer { lock.unlock() }; hits[i] = values; counts[i] = count }
}
private extension Data {
    mutating func put<T>(_ value: T, at offset: Int) { var v = value; Swift.withUnsafeBytes(of: &v) { replaceSubrange(offset..<(offset + $0.count), with: $0) } }
}
