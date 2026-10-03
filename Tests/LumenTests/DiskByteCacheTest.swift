import Foundation
@testable import Lumen
import XCTest

class DiskByteCacheTest: XCTestCase {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    func testWriteReadAndMergeRanges() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try XCTUnwrap(DiskByteCache(directory: directory, key: "title-a", maxBytes: 1_000_000))
        cache.write(Data([1, 2, 3, 4]), at: 0)
        cache.write(Data([5, 6, 7, 8]), at: 4)
        XCTAssertEqual(cache.cachedData(at: 0, maxLength: 8), Data([1, 2, 3, 4, 5, 6, 7, 8]))
        XCTAssertEqual(cache.cachedData(at: 2, maxLength: 4), Data([3, 4, 5, 6]))
        XCTAssertEqual(cache.cachedData(at: 6, maxLength: 100), Data([7, 8]))
        XCTAssertNil(cache.cachedData(at: 8, maxLength: 1))
        cache.close()
    }

    func testGapIsNotServed() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try XCTUnwrap(DiskByteCache(directory: directory, key: "title-b", maxBytes: 1_000_000))
        cache.write(Data([1, 2, 3, 4]), at: 0)
        cache.write(Data([9, 9]), at: 10)
        XCTAssertNil(cache.cachedData(at: 4, maxLength: 4))
        XCTAssertNil(cache.cachedData(at: 8, maxLength: 2))
        XCTAssertEqual(cache.cachedData(at: 10, maxLength: 2), Data([9, 9]))
        cache.close()
    }

    func testIndexPersistsAcrossReopen() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try XCTUnwrap(DiskByteCache(directory: directory, key: "title-c", maxBytes: 1_000_000))
        first.write(Data([1, 2, 3, 4]), at: 100)
        first.contentLength = 5000
        first.contentType = "video/mp4"
        first.close()
        let second = try XCTUnwrap(DiskByteCache(directory: directory, key: "title-c", maxBytes: 1_000_000))
        XCTAssertEqual(second.cachedData(at: 100, maxLength: 4), Data([1, 2, 3, 4]))
        XCTAssertEqual(second.contentLength, 5000)
        XCTAssertEqual(second.contentType, "video/mp4")
        XCTAssertNil(second.cachedData(at: 0, maxLength: 1))
        second.close()
    }

    func testQuotaEvictsOldestEntry() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try XCTUnwrap(DiskByteCache(directory: directory, key: "old-title", maxBytes: 10_000))
        first.write(Data(repeating: 1, count: 6000), at: 0)
        first.close()
        let oldDataPath = directory.appendingPathComponent(DiskByteCache.entryName(for: "old-title")).appendingPathExtension(DiskByteCache.dataPathExtension).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldDataPath))
        let second = try XCTUnwrap(DiskByteCache(directory: directory, key: "new-title", maxBytes: 10_000))
        second.write(Data(repeating: 2, count: 6000), at: 0)
        XCTAssertEqual(second.cachedData(at: 0, maxLength: 6000), Data(repeating: 2, count: 6000))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDataPath))
        second.close()
    }

    func testFarOffsetWriteIsBudgetedByStoredBytes() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let other = try XCTUnwrap(DiskByteCache(directory: directory, key: "other-title", maxBytes: 1_000_000))
        other.write(Data(repeating: 3, count: 4096), at: 0)
        other.close()
        let otherDataPath = directory.appendingPathComponent(DiskByteCache.entryName(for: "other-title")).appendingPathExtension(DiskByteCache.dataPathExtension).path
        let tailOffset = Int64(10) * 1024 * 1024 * 1024
        let cache = try XCTUnwrap(DiskByteCache(directory: directory, key: "large-title", maxBytes: 1_000_000))
        cache.write(Data(repeating: 1, count: 4096), at: tailOffset)
        cache.write(Data(repeating: 2, count: 4096), at: 0)
        XCTAssertEqual(cache.cachedData(at: tailOffset, maxLength: 4096), Data(repeating: 1, count: 4096))
        XCTAssertEqual(cache.cachedData(at: 0, maxLength: 4096), Data(repeating: 2, count: 4096))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherDataPath))
        cache.close()
        let reopened = try XCTUnwrap(DiskByteCache(directory: directory, key: "large-title", maxBytes: 1_000_000))
        XCTAssertEqual(reopened.cachedData(at: tailOffset, maxLength: 4096), Data(repeating: 1, count: 4096))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherDataPath))
        reopened.close()
    }

    func testOversizedWriteIsSkippedWithoutDisablingWrites() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try XCTUnwrap(DiskByteCache(directory: directory, key: "title-d", maxBytes: 10_000))
        cache.write(Data(repeating: 1, count: 20_000), at: 0)
        XCTAssertNil(cache.cachedData(at: 0, maxLength: 1))
        cache.write(Data(repeating: 2, count: 1000), at: 50_000)
        XCTAssertEqual(cache.cachedData(at: 50_000, maxLength: 1000), Data(repeating: 2, count: 1000))
        cache.close()
    }

    func testFailedIndexWriteIsRetriedOnTheNextWrite() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let maxBytes = Int64(64 * 1024 * 1024)
        let flushBytes = 8 * 1024 * 1024
        let cache = try XCTUnwrap(DiskByteCache(directory: directory, key: "title-e", maxBytes: maxBytes))
        let indexURL = directory.appendingPathComponent(DiskByteCache.entryName(for: "title-e")).appendingPathExtension(DiskByteCache.indexPathExtension)
        try FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: true)
        try Data([0]).write(to: indexURL.appendingPathComponent("blocker"))
        cache.write(Data(repeating: 7, count: flushBytes), at: 0)
        try FileManager.default.removeItem(at: indexURL)
        cache.write(Data([9]), at: Int64(flushBytes))
        let reopened = try XCTUnwrap(DiskByteCache(directory: directory, key: "title-e", maxBytes: maxBytes))
        XCTAssertEqual(reopened.cachedData(at: 0, maxLength: 4), Data(repeating: 7, count: 4))
        XCTAssertEqual(reopened.cachedData(at: Int64(flushBytes), maxLength: 1), Data([9]))
        reopened.close()
        cache.close()
    }
}
