@testable import Lumen
import XCTest

class ProAVInitBoundaryScannerTest: XCTestCase {
    private func box(_ type: String, payloadSize: Int = 0) -> Data {
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: UInt32(8 + payloadSize).bigEndian) { Array($0) })
        data.append(contentsOf: Array(type.utf8))
        data.append(Data(repeating: 0xAB, count: payloadSize))
        return data
    }

    private func largesizeBox(_ type: String, payloadSize: Int) -> Data {
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: UInt32(1).bigEndian) { Array($0) })
        data.append(contentsOf: Array(type.utf8))
        data.append(contentsOf: withUnsafeBytes(of: UInt64(16 + payloadSize).bigEndian) { Array($0) })
        data.append(Data(repeating: 0xCD, count: payloadSize))
        return data
    }

    private func zeroSizeBox(_ type: String, payloadSize: Int) -> Data {
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: UInt32(0).bigEndian) { Array($0) })
        data.append(contentsOf: Array(type.utf8))
        data.append(Data(repeating: 0xEF, count: payloadSize))
        return data
    }

    func testSplitBeforeFirstFragment() {
        let initData = box("ftyp", payloadSize: 16) + box("moov", payloadSize: 700)
        let fragmentData = box("moof", payloadSize: 120) + box("mdat", payloadSize: 400)
        var scanner = ProAVInitBoundaryScanner()
        let outcome = scanner.consume(initData + fragmentData)
        XCTAssertEqual(outcome, .split(initSegment: initData, remainder: fragmentData))
    }

    func testChunkedInputSplitsAtSameBoundary() {
        let initData = box("ftyp", payloadSize: 8) + box("moov", payloadSize: 245)
        let fragmentData = box("moof", payloadSize: 61) + box("mdat", payloadSize: 501)
        let full = initData + fragmentData
        var scanner = ProAVInitBoundaryScanner()
        var reassembled = Data()
        var splitInit: Data?
        var offset = 0
        while offset < full.count {
            let end = min(offset + 7, full.count)
            let chunk = full.subdata(in: offset ..< end)
            offset = end
            if splitInit == nil {
                switch scanner.consume(chunk) {
                case .buffering:
                    break
                case let .split(initSegment, remainder):
                    splitInit = initSegment
                    reassembled.append(initSegment)
                    reassembled.append(remainder)
                case .malformed:
                    XCTFail("unexpected malformed outcome")
                    return
                }
            } else {
                reassembled.append(chunk)
            }
        }
        XCTAssertEqual(splitInit, initData)
        XCTAssertEqual(reassembled, full)
    }

    func testLargesizeBoxStaysInInitSegment() {
        let initData = box("ftyp", payloadSize: 16) + largesizeBox("moov", payloadSize: 300)
        let fragmentData = box("moof", payloadSize: 32)
        var scanner = ProAVInitBoundaryScanner()
        let outcome = scanner.consume(initData + fragmentData)
        XCTAssertEqual(outcome, .split(initSegment: initData, remainder: fragmentData))
    }

    func testIncompleteBoxKeepsBuffering() {
        let initData = box("ftyp", payloadSize: 16) + box("moov", payloadSize: 300)
        var scanner = ProAVInitBoundaryScanner()
        XCTAssertEqual(scanner.consume(initData.subdata(in: 0 ..< 5)), .buffering)
        XCTAssertEqual(scanner.consume(initData.subdata(in: 5 ..< initData.count)), .buffering)
        let fragmentData = box("moof", payloadSize: 24)
        XCTAssertEqual(scanner.consume(fragmentData), .split(initSegment: initData, remainder: fragmentData))
    }

    func testZeroSizeBoxNeverSplits() {
        let data = box("ftyp", payloadSize: 16) + zeroSizeBox("mdat", payloadSize: 64) + box("moof", payloadSize: 24)
        var scanner = ProAVInitBoundaryScanner()
        XCTAssertEqual(scanner.consume(data), .buffering)
        XCTAssertEqual(scanner.consume(box("moof", payloadSize: 8)), .buffering)
    }

    func testUndersizedBoxIsMalformed() {
        var data = box("ftyp", payloadSize: 16)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(3).bigEndian) { Array($0) })
        data.append(contentsOf: Array("free".utf8))
        var scanner = ProAVInitBoundaryScanner()
        XCTAssertEqual(scanner.consume(data), .malformed)
    }

    func testUndersizedLargesizeBoxIsMalformed() {
        var data = box("ftyp", payloadSize: 16)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(1).bigEndian) { Array($0) })
        data.append(contentsOf: Array("free".utf8))
        data.append(contentsOf: withUnsafeBytes(of: UInt64(8).bigEndian) { Array($0) })
        var scanner = ProAVInitBoundaryScanner()
        XCTAssertEqual(scanner.consume(data), .malformed)
    }

    func testFragmentWithoutInitSegmentIsMalformed() {
        let data = box("moof", payloadSize: 24) + box("mdat", payloadSize: 64)
        var scanner = ProAVInitBoundaryScanner()
        XCTAssertEqual(scanner.consume(data), .malformed)
    }
}
