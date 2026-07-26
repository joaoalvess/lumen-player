@testable import Lumen
import XCTest

class ProAVHDR10PlusScannerTest: XCTestCase {
    private let hdr10PlusPayloadHeader: [UInt8] = [0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04]

    private func escaped(_ rbsp: [UInt8]) -> [UInt8] {
        var output = [UInt8]()
        var zeroRun = 0
        for byte in rbsp {
            if zeroRun >= 2, byte <= 3 {
                output.append(0x03)
                zeroRun = 0
            }
            output.append(byte)
            zeroRun = byte == 0 ? zeroRun + 1 : 0
        }
        return output
    }

    private func seiNALUnit(type: UInt8 = 39, payloadType: Int, payload: [UInt8]) -> [UInt8] {
        var rbsp = [UInt8]()
        var remainingType = payloadType
        while remainingType >= 255 {
            rbsp.append(0xFF)
            remainingType -= 255
        }
        rbsp.append(UInt8(remainingType))
        var remainingSize = payload.count
        while remainingSize >= 255 {
            rbsp.append(0xFF)
            remainingSize -= 255
        }
        rbsp.append(UInt8(remainingSize))
        rbsp.append(contentsOf: payload)
        rbsp.append(0x80)
        return [(type << 1) & 0x7E, 0x01] + escaped(rbsp)
    }

    private func lengthPrefixed(_ nalUnits: [[UInt8]], nalLengthSize: Int = 4) -> Data {
        var data = Data()
        for nalUnit in nalUnits {
            for shift in stride(from: (nalLengthSize - 1) * 8, through: 0, by: -8) {
                data.append(UInt8((nalUnit.count >> shift) & 0xFF))
            }
            data.append(contentsOf: nalUnit)
        }
        return data
    }

    private func videoNALUnit(byteCount: Int) -> [UInt8] {
        [0x26, 0x01] + [UInt8](repeating: 0x77, count: byteCount)
    }

    func testDetectsHDR10PlusPrefixSEI() {
        let payload = hdr10PlusPayloadHeader + [0x01, 0x40, 0x00, 0x0C, 0x80]
        let data = lengthPrefixed([videoNALUnit(byteCount: 24), seiNALUnit(payloadType: 4, payload: payload)])
        XCTAssertTrue(ProAVHDR10PlusScanner.containsHDR10Plus(payload: data, nalLengthSize: 4))
    }

    func testDetectsHDR10PlusWithEmulationPreventionBytes() {
        let payload = hdr10PlusPayloadHeader + [0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x02, 0x33]
        let nalUnit = seiNALUnit(payloadType: 4, payload: payload)
        XCTAssertTrue(nalUnit.contains(0x03), "the fixture should carry emulation prevention bytes")
        let data = lengthPrefixed([nalUnit])
        XCTAssertTrue(ProAVHDR10PlusScanner.containsHDR10Plus(payload: data, nalLengthSize: 4))
    }

    func testDetectsHDR10PlusAfterAnotherSEIMessage() {
        var rbsp = [UInt8]()
        rbsp.append(contentsOf: [137, 24] + [UInt8](repeating: 0x11, count: 24))
        rbsp.append(contentsOf: [4, UInt8(hdr10PlusPayloadHeader.count + 1)] + hdr10PlusPayloadHeader + [0x01])
        rbsp.append(0x80)
        let data = lengthPrefixed([[0x4E, 0x01] + escaped(rbsp)])
        XCTAssertTrue(ProAVHDR10PlusScanner.containsHDR10Plus(payload: data, nalLengthSize: 4))
    }

    func testDetectsHDR10PlusWithTwoByteLengthPrefixes() {
        let payload = hdr10PlusPayloadHeader + [0x01, 0x40]
        let data = lengthPrefixed([seiNALUnit(payloadType: 4, payload: payload)], nalLengthSize: 2)
        XCTAssertTrue(ProAVHDR10PlusScanner.containsHDR10Plus(payload: data, nalLengthSize: 2))
    }

    func testIgnoresClosedCaptionUserData() {
        let payload: [UInt8] = [0xB5, 0x00, 0x31, 0x47, 0x41, 0x39, 0x34, 0x03, 0x40]
        let data = lengthPrefixed([seiNALUnit(payloadType: 4, payload: payload)])
        XCTAssertFalse(ProAVHDR10PlusScanner.containsHDR10Plus(payload: data, nalLengthSize: 4))
    }

    func testIgnoresOtherSamsungApplications() {
        let wrongApplication: [UInt8] = [0xB5, 0x00, 0x3C, 0x00, 0x01, 0x05, 0x01]
        XCTAssertFalse(ProAVHDR10PlusScanner.containsHDR10Plus(payload: lengthPrefixed([seiNALUnit(payloadType: 4, payload: wrongApplication)]), nalLengthSize: 4))
        let wrongOrientedCode: [UInt8] = [0xB5, 0x00, 0x3C, 0x00, 0x02, 0x04, 0x01]
        XCTAssertFalse(ProAVHDR10PlusScanner.containsHDR10Plus(payload: lengthPrefixed([seiNALUnit(payloadType: 4, payload: wrongOrientedCode)]), nalLengthSize: 4))
        let wrongCountry: [UInt8] = [0xB4, 0x00, 0x3C, 0x00, 0x01, 0x04, 0x01]
        XCTAssertFalse(ProAVHDR10PlusScanner.containsHDR10Plus(payload: lengthPrefixed([seiNALUnit(payloadType: 4, payload: wrongCountry)]), nalLengthSize: 4))
    }

    func testIgnoresOtherPayloadTypes() {
        let payload = hdr10PlusPayloadHeader + [0x01]
        let data = lengthPrefixed([seiNALUnit(payloadType: 137, payload: payload)])
        XCTAssertFalse(ProAVHDR10PlusScanner.containsHDR10Plus(payload: data, nalLengthSize: 4))
    }

    func testIgnoresNonPrefixSEINALUnits() {
        let payload = hdr10PlusPayloadHeader + [0x01]
        XCTAssertFalse(ProAVHDR10PlusScanner.containsHDR10Plus(payload: lengthPrefixed([seiNALUnit(type: 62, payloadType: 4, payload: payload)]), nalLengthSize: 4))
        XCTAssertFalse(ProAVHDR10PlusScanner.containsHDR10Plus(payload: lengthPrefixed([seiNALUnit(type: 40, payloadType: 4, payload: payload)]), nalLengthSize: 4))
    }

    func testRefusesTruncatedAndUnsupportedPayloads() {
        let payload = hdr10PlusPayloadHeader + [0x01]
        let data = lengthPrefixed([seiNALUnit(payloadType: 4, payload: payload)])
        XCTAssertFalse(ProAVHDR10PlusScanner.containsHDR10Plus(payload: data.prefix(data.count - 3), nalLengthSize: 4))
        XCTAssertFalse(ProAVHDR10PlusScanner.containsHDR10Plus(payload: data, nalLengthSize: 5))
        XCTAssertFalse(ProAVHDR10PlusScanner.containsHDR10Plus(payload: Data(), nalLengthSize: 4))
    }

    func testSEIMessageWithOversizedPayloadIsRefused() {
        var rbsp: [UInt8] = [4, 200]
        rbsp.append(contentsOf: hdr10PlusPayloadHeader)
        let data = lengthPrefixed([[0x4E, 0x01] + rbsp])
        XCTAssertFalse(ProAVHDR10PlusScanner.containsHDR10Plus(payload: data, nalLengthSize: 4))
    }

    private func ftypBox(brands: [String]) -> Data {
        var payload = Array("iso5".utf8) + [UInt8](repeating: 0, count: 4)
        for brand in brands {
            payload.append(contentsOf: Array(brand.utf8))
        }
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: UInt32(8 + payload.count).bigEndian) { Array($0) })
        data.append(contentsOf: Array("ftyp".utf8))
        data.append(contentsOf: payload)
        return data
    }

    func testAppendsTheBrandToTheFileTypeBox() {
        let initSegment = ftypBox(brands: ["iso5", "iso6", "mp41"]) + Data(repeating: 0xAB, count: 64)
        guard let updated = ProAVHDR10PlusScanner.appendingCompatibleBrand("cdm4", toInitSegment: initSegment) else {
            XCTFail("the file type box was refused")
            return
        }
        XCTAssertEqual(updated.count, initSegment.count + 4)
        XCTAssertEqual(updated.prefix(4), Data([0, 0, 0, 32]))
        XCTAssertEqual(updated.subdata(in: 28 ..< 32), Data("cdm4".utf8))
        XCTAssertEqual(updated.subdata(in: 4 ..< 28), initSegment.subdata(in: 4 ..< 28))
        XCTAssertEqual(updated.suffix(64), initSegment.suffix(64))
    }

    func testKeepsAnInitSegmentThatAlreadyDeclaresTheBrand() {
        let initSegment = ftypBox(brands: ["iso5", "cdm4"]) + Data(repeating: 0xCD, count: 16)
        XCTAssertEqual(ProAVHDR10PlusScanner.appendingCompatibleBrand("cdm4", toInitSegment: initSegment), initSegment)
    }

    func testRefusesInitSegmentsThatDoNotStartWithTheFileTypeBox() {
        var moovFirst = Data()
        moovFirst.append(contentsOf: withUnsafeBytes(of: UInt32(24).bigEndian) { Array($0) })
        moovFirst.append(contentsOf: Array("moov".utf8))
        moovFirst.append(Data(repeating: 0, count: 16))
        XCTAssertNil(ProAVHDR10PlusScanner.appendingCompatibleBrand("cdm4", toInitSegment: moovFirst))
        XCTAssertNil(ProAVHDR10PlusScanner.appendingCompatibleBrand("cdm4", toInitSegment: Data(repeating: 0, count: 8)))
        XCTAssertNil(ProAVHDR10PlusScanner.appendingCompatibleBrand("cdm", toInitSegment: ftypBox(brands: ["iso5"])))
    }

    func testRefusesFileTypeBoxesLargerThanTheInitSegment() {
        var truncated = ftypBox(brands: ["iso5", "iso6"])
        truncated.removeLast(4)
        XCTAssertNil(ProAVHDR10PlusScanner.appendingCompatibleBrand("cdm4", toInitSegment: truncated))
    }
}
