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
    private let directory: URL
    private let dataURL: URL
    private let indexURL: URL
    private let maxBytes: Int64
    private var descriptor = Int32(-1)
    private var ranges = [DiskByteCacheRange]()
    private var logicalEnd = Int64(0)
    private var otherEntriesBytes = Int64(0)
    private var unsyncedBytes = Int64(0)
    private var isWritable = true
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
        logicalEnd = ranges.map(\.end).max() ?? 0
        let now = Date()
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: dataURL.path)
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: indexURL.path)
        otherEntriesBytes = DiskByteCache.usedBytes(in: directory, excluding: [dataURL, indexURL])
        if otherEntriesBytes + logicalEnd > maxBytes {
            evictOtherEntries(required: logicalEnd)
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
            defer { lock.unlock() }
            guard storedContentLength != newValue else {
                return
            }
            storedContentLength = newValue
            persistIndex()
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
            defer { lock.unlock() }
            guard storedContentType != newValue else {
                return
            }
            storedContentType = newValue
            persistIndex()
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
        guard offset >= 0, !data.isEmpty else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        guard isWritable, descriptor >= 0 else {
            return
        }
        let newEnd = offset + Int64(data.count)
        let projectedEnd = max(logicalEnd, newEnd)
        if otherEntriesBytes + projectedEnd > maxBytes {
            evictOtherEntries(required: projectedEnd)
            if otherEntriesBytes + projectedEnd > maxBytes {
                isWritable = false
                return
            }
        }
        let written = data.withUnsafeBytes { pointer -> Int in
            guard let base = pointer.baseAddress else {
                return -1
            }
            return pwrite(descriptor, base, data.count, off_t(offset))
        }
        guard written == data.count else {
            return
        }
        logicalEnd = projectedEnd
        insert(DiskByteCacheRange(offset: offset, length: Int64(data.count)))
        unsyncedBytes += Int64(data.count)
        if unsyncedBytes >= DiskByteCache.indexFlushBytes {
            persistIndex()
        }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else {
            return
        }
        persistIndex()
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit {
        close()
    }

    static func entryName(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func insert(_ range: DiskByteCacheRange) {
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
        ranges = merged
    }

    private func persistIndex() {
        guard descriptor >= 0 else {
            return
        }
        fsync(descriptor)
        let index = DiskByteCacheIndex(version: DiskByteCache.indexVersion, contentLength: storedContentLength, contentType: storedContentType, ranges: ranges)
        guard let encoded = try? JSONEncoder().encode(index) else {
            return
        }
        if (try? encoded.write(to: indexURL, options: .atomic)) != nil {
            unsyncedBytes = 0
        }
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
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else {
            return []
        }
        return urls.filter { $0.pathExtension == dataPathExtension }.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let indexURL = url.deletingPathExtension().appendingPathExtension(indexPathExtension)
            let size = fileLength(at: url) + fileLength(at: indexURL)
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
