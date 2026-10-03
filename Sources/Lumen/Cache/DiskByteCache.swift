import CryptoKit
import Darwin
import Foundation

public struct DiskByteCacheRange: Codable, Equatable {
    public var offset: Int64
    public var length: Int64

    public var end: Int64 {
        offset + length
    }

    public init(offset: Int64, length: Int64) {
        self.offset = offset
        self.length = length
    }
}

struct DiskByteCacheIndex: Codable {
    var version: Int
    var contentLength: Int64?
    var contentType: String?
    var ranges: [DiskByteCacheRange]
}

public final class DiskByteCache {
    static let indexVersion = 1
    static let dataPathExtension = "data"
    static let indexPathExtension = "index"
    private static let indexFlushBytes = Int64(8 * 1024 * 1024)
    private let lock = NSLock()
    private let persistLock = NSLock()
    private let directory: URL
    private let dataURL: URL
    private let indexURL: URL
    private let maxBytes: Int64
    private var descriptor = Int32(-1)
    private var ranges = [DiskByteCacheRange]()
    private var otherEntriesBytes = Int64(0)
    private var unsyncedBytes = Int64(0)
    private var indexGeneration = 0
    private var persistedGeneration = 0
    private var storedContentLength: Int64?
    private var storedContentType: String?

    public init?(directory: URL, key: String, maxBytes: Int64) {
        guard maxBytes > 0, !key.isEmpty else {
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        self.directory = directory
        self.maxBytes = maxBytes
        let name = DiskByteCache.entryName(for: key)
        dataURL = directory.appendingPathComponent(name).appendingPathExtension(DiskByteCache.dataPathExtension)
        indexURL = directory.appendingPathComponent(name).appendingPathExtension(DiskByteCache.indexPathExtension)
        if let index = DiskByteCache.loadIndex(at: indexURL),
           DiskByteCache.fileLength(at: dataURL) >= index.ranges.map(\.end).max() ?? 0
        {
            ranges = index.ranges
            storedContentLength = index.contentLength
            storedContentType = index.contentType
        } else {
            try? FileManager.default.removeItem(at: dataURL)
            try? FileManager.default.removeItem(at: indexURL)
        }
        descriptor = open(dataURL.path, O_RDWR | O_CREAT, 0o644)
        guard descriptor >= 0 else {
            return nil
        }
        let cachedBytes = DiskByteCache.storedBytes(in: ranges)
        let now = Date()
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: dataURL.path)
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: indexURL.path)
        otherEntriesBytes = DiskByteCache.usedBytes(in: directory, excluding: [dataURL, indexURL])
        if otherEntriesBytes + cachedBytes > maxBytes {
            evictOtherEntries(required: cachedBytes)
        }
    }

    public var contentLength: Int64? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedContentLength
        }
        set {
            lock.lock()
            guard storedContentLength != newValue else {
                lock.unlock()
                return
            }
            storedContentLength = newValue
            let snapshot = makeIndexSnapshot()
            lock.unlock()
            persist(snapshot)
        }
    }

    public var contentType: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedContentType
        }
        set {
            lock.lock()
            guard storedContentType != newValue else {
                lock.unlock()
                return
            }
            storedContentType = newValue
            let snapshot = makeIndexSnapshot()
            lock.unlock()
            persist(snapshot)
        }
    }

    public func cachedData(at offset: Int64, maxLength: Int) -> Data? {
        guard offset >= 0, maxLength > 0 else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else {
            return nil
        }
        guard let range = ranges.first(where: { $0.offset <= offset && offset < $0.end }) else {
            return nil
        }
        let count = Int(min(Int64(maxLength), range.end - offset))
        var data = Data(count: count)
        let bytesRead = data.withUnsafeMutableBytes { pointer -> Int in
            guard let base = pointer.baseAddress else {
                return -1
            }
            return pread(descriptor, base, count, off_t(offset))
        }
        guard bytesRead == count else {
            return nil
        }
        return data
    }

    public func write(_ data: Data, at offset: Int64) {
        guard offset >= 0, !data.isEmpty, let snapshot = store(data, at: offset) else {
            return
        }
        persist(snapshot)
    }

    public func close() {
        persistLock.lock()
        defer { persistLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else {
            return
        }
        _ = writeIndex(makeIndexSnapshot(), fileDescriptor: descriptor)
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit {
        close()
    }

    static func entryName(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func store(_ data: Data, at offset: Int64) -> IndexSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else {
            return nil
        }
        let updatedRanges = DiskByteCache.inserting(DiskByteCacheRange(offset: offset, length: Int64(data.count)), into: ranges)
        let projectedBytes = DiskByteCache.storedBytes(in: updatedRanges)
        if projectedBytes <= maxBytes, otherEntriesBytes + projectedBytes > maxBytes {
            evictOtherEntries(required: projectedBytes)
        }
        guard otherEntriesBytes + projectedBytes <= maxBytes else {
            return nil
        }
        let written = data.withUnsafeBytes { pointer -> Int in
            guard let base = pointer.baseAddress else {
                return -1
            }
            return pwrite(descriptor, base, data.count, off_t(offset))
        }
        guard written == data.count else {
            return nil
        }
        ranges = updatedRanges
        unsyncedBytes += Int64(data.count)
        guard unsyncedBytes >= DiskByteCache.indexFlushBytes else {
            return nil
        }
        return makeIndexSnapshot()
    }

    private static func inserting(_ range: DiskByteCacheRange, into ranges: [DiskByteCacheRange]) -> [DiskByteCacheRange] {
        var all = ranges
        all.append(range)
        all.sort { $0.offset < $1.offset }
        var merged = [DiskByteCacheRange]()
        for current in all {
            if var last = merged.last, current.offset <= last.end {
                last.length = max(last.end, current.end) - last.offset
                merged[merged.count - 1] = last
            } else {
                merged.append(current)
            }
        }
        return merged
    }

    private static func storedBytes(in ranges: [DiskByteCacheRange]) -> Int64 {
        ranges.reduce(Int64(0)) { $0 + $1.length }
    }

    private struct IndexSnapshot {
        let generation: Int
        let coveredBytes: Int64
        let index: DiskByteCacheIndex
    }

    private func makeIndexSnapshot() -> IndexSnapshot {
        indexGeneration += 1
        let index = DiskByteCacheIndex(version: DiskByteCache.indexVersion, contentLength: storedContentLength, contentType: storedContentType, ranges: ranges)
        return IndexSnapshot(generation: indexGeneration, coveredBytes: unsyncedBytes, index: index)
    }

    private func persist(_ snapshot: IndexSnapshot) {
        persistLock.lock()
        defer { persistLock.unlock() }
        lock.lock()
        let currentDescriptor = descriptor
        lock.unlock()
        guard currentDescriptor >= 0, writeIndex(snapshot, fileDescriptor: currentDescriptor) else {
            return
        }
        lock.lock()
        unsyncedBytes = max(0, unsyncedBytes - snapshot.coveredBytes)
        lock.unlock()
    }

    private func writeIndex(_ snapshot: IndexSnapshot, fileDescriptor: Int32) -> Bool {
        guard snapshot.generation > persistedGeneration else {
            return false
        }
        fsync(fileDescriptor)
        guard let encoded = try? JSONEncoder().encode(snapshot.index),
              (try? encoded.write(to: indexURL, options: .atomic)) != nil
        else {
            return false
        }
        persistedGeneration = snapshot.generation
        return true
    }

    private func evictOtherEntries(required: Int64) {
        let keep = Set([dataURL.lastPathComponent, indexURL.lastPathComponent])
        let entries = DiskByteCache.entries(in: directory)
            .filter { !keep.contains($0.dataURL.lastPathComponent) }
            .sorted { $0.date < $1.date }
        var used = otherEntriesBytes + required
        for entry in entries {
            guard used > maxBytes else {
                break
            }
            try? FileManager.default.removeItem(at: entry.dataURL)
            try? FileManager.default.removeItem(at: entry.indexURL)
            used -= entry.size
        }
        otherEntriesBytes = DiskByteCache.usedBytes(in: directory, excluding: [dataURL, indexURL])
    }

    private struct Entry {
        let dataURL: URL
        let indexURL: URL
        let size: Int64
        let date: Date
    }

    private static func entries(in directory: URL) -> [Entry] {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else {
            return []
        }
        return urls.filter { $0.pathExtension == dataPathExtension }.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let indexURL = url.deletingPathExtension().appendingPathExtension(indexPathExtension)
            let size = allocatedLength(at: url) + allocatedLength(at: indexURL)
            return Entry(dataURL: url, indexURL: indexURL, size: size, date: values?.contentModificationDate ?? .distantPast)
        }
    }

    private static func usedBytes(in directory: URL, excluding excluded: [URL]) -> Int64 {
        let excludedNames = Set(excluded.map(\.lastPathComponent))
        return entries(in: directory).reduce(Int64(0)) { partial, entry in
            excludedNames.contains(entry.dataURL.lastPathComponent) ? partial : partial + entry.size
        }
    }

    private static func fileLength(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private static func allocatedLength(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
    }

    private static func loadIndex(at url: URL) -> DiskByteCacheIndex? {
        guard let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(DiskByteCacheIndex.self, from: data),
              index.version == indexVersion,
              index.ranges.allSatisfy({ $0.offset >= 0 && $0.length > 0 })
        else {
            return nil
        }
        return index
    }
}
