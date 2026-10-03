import Foundation
@testable import Lumen
import XCTest

class DiskCacheURLReaderTest: XCTestCase {
    func testParseContentRange() {
        XCTAssertEqual(DiskCacheURLReader.parseContentRange("bytes 0-99/100"), DiskCacheURLReader.ContentRange(start: 0, end: 99, total: 100))
        XCTAssertEqual(DiskCacheURLReader.parseContentRange("bytes 500-999/*"), DiskCacheURLReader.ContentRange(start: 500, end: 999, total: nil))
        XCTAssertNil(DiskCacheURLReader.parseContentRange("bytes */100"))
        XCTAssertNil(DiskCacheURLReader.parseContentRange("bytes 99-0/100"))
        XCTAssertNil(DiskCacheURLReader.parseContentRange("bytes 0-100/100"))
        XCTAssertNil(DiskCacheURLReader.parseContentRange("items 0-99/100"))
        XCTAssertNil(DiskCacheURLReader.parseContentRange("bytes 0-99"))
    }

    func testPartialResponseMustStartAtRequestedOffset() {
        XCTAssertTrue(DiskCacheURLReader.isValidPartialResponse(contentRange: "bytes 1048576-2097151/30000000000", offset: 1_048_576, bodyLength: 1_048_576))
        XCTAssertTrue(DiskCacheURLReader.isValidPartialResponse(contentRange: "bytes 1048576-2097151/30000000000", offset: 1_048_576, bodyLength: 524_288))
        XCTAssertFalse(DiskCacheURLReader.isValidPartialResponse(contentRange: "bytes 1044480-2097151/30000000000", offset: 1_048_576, bodyLength: 1_048_576))
        XCTAssertFalse(DiskCacheURLReader.isValidPartialResponse(contentRange: "bytes 0-1048575/30000000000", offset: 4096, bodyLength: 1_048_576))
        XCTAssertFalse(DiskCacheURLReader.isValidPartialResponse(contentRange: "bytes 1048576-1049599/30000000000", offset: 1_048_576, bodyLength: 2048))
        XCTAssertFalse(DiskCacheURLReader.isValidPartialResponse(contentRange: nil, offset: 0, bodyLength: 1024))
    }
}
