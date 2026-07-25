import Libavcodec
@testable import Lumen
import XCTest

class DOVIPacketRewriterTest: XCTestCase {
    private func nalUnit(type: UInt8, body: [UInt8]) -> [UInt8] {
        [type << 1, 1] + body
    }

    private func lengthPrefix(for count: Int, lengthSize: Int) -> [UInt8] {
        var remaining = count
        var prefix = [UInt8](repeating: 0, count: lengthSize)
        for index in stride(from: lengthSize - 1, through: 0, by: -1) {
            prefix[index] = UInt8(remaining & 0xFF)
            remaining >>= 8
        }
        return prefix
    }

    private func payload(of nalUnits: [[UInt8]], lengthSize: Int) -> Data {
        var data = Data()
        for unit in nalUnits {
            data.append(contentsOf: lengthPrefix(for: unit.count, lengthSize: lengthSize))
            data.append(contentsOf: unit)
        }
        return data
    }

    private func makePacket(payload: Data) throws -> UnsafeMutablePointer<AVPacket>? {
        let packet = try XCTUnwrap(av_packet_alloc())
        XCTAssertEqual(av_new_packet(packet, Int32(payload.count)), 0)
        let destination = try XCTUnwrap(packet.pointee.data)
        for (index, byte) in payload.enumerated() {
            destination[index] = byte
        }
        packet.pointee.pts = 1024
        packet.pointee.dts = 512
        packet.pointee.duration = 2002
        packet.pointee.flags = AV_PKT_FLAG_KEY
        packet.pointee.stream_index = 3
        packet.pointee.time_base = AVRational(num: 1, den: 90000)
        return packet
    }

    private func payloadBytes(of packet: UnsafeMutablePointer<AVPacket>) throws -> Data {
        let data = try XCTUnwrap(packet.pointee.data)
        return Data(bytes: data, count: Int(packet.pointee.size))
    }

    func testRewritePacketReplacesPayloadAndKeepsProperties() throws {
        let vcl = nalUnit(type: 1, body: [0xAA, 0xBB, 0xCC])
        let enhancementLayer = nalUnit(type: 63, body: [0x01, 0x02, 0x03])
        var allocated = try makePacket(payload: payload(of: [vcl, enhancementLayer], lengthSize: 4))
        defer { av_packet_free(&allocated) }
        let packet = try XCTUnwrap(allocated)
        XCTAssertFalse(try DOVIPacketRewriter.rewrite(packet: packet, nalLengthSize: 4))
        let expected = payload(of: [vcl], lengthSize: 4)
        XCTAssertEqual(Int(packet.pointee.size), expected.count)
        XCTAssertEqual(try payloadBytes(of: packet), expected)
        XCTAssertNotNil(packet.pointee.buf)
        XCTAssertEqual(packet.pointee.pts, 1024)
        XCTAssertEqual(packet.pointee.dts, 512)
        XCTAssertEqual(packet.pointee.duration, 2002)
        XCTAssertEqual(packet.pointee.flags, AV_PKT_FLAG_KEY)
        XCTAssertEqual(packet.pointee.stream_index, 3)
        XCTAssertEqual(packet.pointee.time_base.num, 1)
        XCTAssertEqual(packet.pointee.time_base.den, 90000)
    }

    func testRewritePacketLeavesTheOriginalIntactWhenTheWalkerFails() throws {
        var input = Data(lengthPrefix(for: 12, lengthSize: 4))
        input.append(contentsOf: [0x02, 0x01, 0xAA])
        var allocated = try makePacket(payload: input)
        defer { av_packet_free(&allocated) }
        let packet = try XCTUnwrap(allocated)
        XCTAssertThrowsError(try DOVIPacketRewriter.rewrite(packet: packet, nalLengthSize: 4)) { error in
            XCTAssertEqual(error as? DOVIPacketRewriteError, .truncatedNALUnit)
        }
        XCTAssertEqual(Int(packet.pointee.size), input.count)
        XCTAssertEqual(try payloadBytes(of: packet), input)
        XCTAssertEqual(packet.pointee.pts, 1024)
    }

    func testRewritePacketWithoutPayloadFails() throws {
        var allocated: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&allocated) }
        let packet = try XCTUnwrap(allocated)
        XCTAssertThrowsError(try DOVIPacketRewriter.rewrite(packet: packet, nalLengthSize: 4)) { error in
            XCTAssertEqual(error as? DOVIPacketRewriteError, .missingPayload)
        }
    }

    func testRewriteConvertsRPUDropsEnhancementLayerAndCopiesOthers() throws {
        let vcl = nalUnit(type: 1, body: [0xAA, 0xBB, 0xCC])
        let enhancementLayer = nalUnit(type: 63, body: [0x01, 0x02, 0x03, 0x04])
        let rpu = nalUnit(type: 62, body: [0x19, 0x08, 0x09])
        let replacement: [UInt8] = [0x7C, 0x01, 0x99, 0x98, 0x97, 0x96, 0x95]
        let input = payload(of: [vcl, enhancementLayer, rpu], lengthSize: 4)
        var seenRPU: Data?
        let output = try DOVIPacketRewriter.rewrite(payload: input, nalLengthSize: 4) { unit in
            seenRPU = unit
            return Data(replacement)
        }
        XCTAssertEqual(seenRPU, Data(rpu))
        XCTAssertEqual(output, payload(of: [vcl, replacement], lengthSize: 4))
    }

    func testRewriteWithThreeByteLengthPrefixes() throws {
        let vcl = nalUnit(type: 19, body: [0x11, 0x22])
        let rpu = nalUnit(type: 62, body: [0x19, 0x08])
        let replacement: [UInt8] = [0x7C, 0x01, 0x42]
        let input = payload(of: [rpu, vcl], lengthSize: 3)
        let output = try DOVIPacketRewriter.rewrite(payload: input, nalLengthSize: 3) { _ in
            Data(replacement)
        }
        XCTAssertEqual(output, payload(of: [replacement, vcl], lengthSize: 3))
        XCTAssertEqual([UInt8](output.prefix(3)), [0x00, 0x00, 0x03])
    }

    func testRewriteRecalculatesPrefixWhenRPULengthChanges() throws {
        let rpu = nalUnit(type: 62, body: [UInt8](repeating: 0x55, count: 300))
        let vcl = nalUnit(type: 0, body: [0x01])
        let replacement: [UInt8] = [0x7C, 0x01, 0x0A, 0x0B]
        let input = payload(of: [rpu, vcl], lengthSize: 4)
        let output = try DOVIPacketRewriter.rewrite(payload: input, nalLengthSize: 4) { _ in
            Data(replacement)
        }
        XCTAssertEqual([UInt8](output.prefix(4)), [0x00, 0x00, 0x00, 0x04])
        XCTAssertEqual(output, payload(of: [replacement, vcl], lengthSize: 4))
    }

    func testRewriteFailsWhenPacketContainsOnlyEnhancementLayer() {
        let input = payload(of: [nalUnit(type: 63, body: [0x01, 0x02])], lengthSize: 4)
        XCTAssertThrowsError(try DOVIPacketRewriter.rewrite(payload: input, nalLengthSize: 4) { _ in nil }) { error in
            XCTAssertEqual(error as? DOVIPacketRewriteError, .emptyRewrittenPayload)
        }
    }

    func testRewritePassesPacketWithoutRPUUnchanged() throws {
        let input = payload(of: [nalUnit(type: 32, body: [0x01]),
                                 nalUnit(type: 1, body: [0x02, 0x03])], lengthSize: 4)
        var transformed = false
        let output = try DOVIPacketRewriter.rewrite(payload: input, nalLengthSize: 4) { unit in
            transformed = true
            return unit
        }
        XCTAssertFalse(transformed)
        XCTAssertEqual(output, input)
    }

    func testRewriteFailsOnTruncatedLengthPrefix() {
        var input = payload(of: [nalUnit(type: 1, body: [0xAA])], lengthSize: 4)
        input.append(contentsOf: [0x00, 0x00])
        XCTAssertThrowsError(try DOVIPacketRewriter.rewrite(payload: input, nalLengthSize: 4) { unit in unit }) { error in
            XCTAssertEqual(error as? DOVIPacketRewriteError, .truncatedLengthPrefix)
        }
    }

    func testRewriteFailsOnTruncatedNALUnit() {
        var input = Data(lengthPrefix(for: 10, lengthSize: 4))
        input.append(contentsOf: [0x02, 0x01, 0xAA, 0xBB])
        XCTAssertThrowsError(try DOVIPacketRewriter.rewrite(payload: input, nalLengthSize: 4) { unit in unit }) { error in
            XCTAssertEqual(error as? DOVIPacketRewriteError, .truncatedNALUnit)
        }
    }

    func testRewriteFailsOnZeroNALUnitLength() {
        let input = Data([0x00, 0x00, 0x00, 0x00])
        XCTAssertThrowsError(try DOVIPacketRewriter.rewrite(payload: input, nalLengthSize: 4) { unit in unit }) { error in
            XCTAssertEqual(error as? DOVIPacketRewriteError, .invalidNALUnitLength)
        }
    }

    func testRewriteFailsWhenRPUConversionFails() {
        let input = payload(of: [nalUnit(type: 62, body: [0x19, 0x08])], lengthSize: 4)
        XCTAssertThrowsError(try DOVIPacketRewriter.rewrite(payload: input, nalLengthSize: 4) { _ in nil }) { error in
            XCTAssertEqual(error as? DOVIPacketRewriteError, .rpuConversionFailed)
        }
    }

    func testRewriteRejectsUnsupportedLengthSize() {
        let input = payload(of: [nalUnit(type: 1, body: [0xAA])], lengthSize: 4)
        XCTAssertThrowsError(try DOVIPacketRewriter.rewrite(payload: input, nalLengthSize: 5) { unit in unit }) { error in
            XCTAssertEqual(error as? DOVIPacketRewriteError, .unsupportedNALLengthSize)
        }
    }

    func testHEVCNALUnitLengthSizeReadsHVCC() {
        var hvcc = [UInt8](repeating: 0, count: 23)
        hvcc[0] = 1
        hvcc[21] = 0xFF
        XCTAssertEqual(hvcc.withUnsafeBufferPointer { DOVIPacketRewriter.hevcNALUnitLengthSize(hvcC: $0.baseAddress, size: Int32(hvcc.count)) }, 4)
        hvcc[21] = 0xFE
        XCTAssertEqual(hvcc.withUnsafeBufferPointer { DOVIPacketRewriter.hevcNALUnitLengthSize(hvcC: $0.baseAddress, size: Int32(hvcc.count)) }, 3)
        XCTAssertNil(hvcc.withUnsafeBufferPointer { DOVIPacketRewriter.hevcNALUnitLengthSize(hvcC: $0.baseAddress, size: 22) })
        hvcc[0] = 0
        XCTAssertNil(hvcc.withUnsafeBufferPointer { DOVIPacketRewriter.hevcNALUnitLengthSize(hvcC: $0.baseAddress, size: Int32(hvcc.count)) })
        XCTAssertNil(DOVIPacketRewriter.hevcNALUnitLengthSize(hvcC: nil, size: 23))
    }

    func testProfile81ConfigurationRecordBytesFromSourceBytes() {
        let profile7Source: [UInt8] = [1, 0, 7, 6, 1, 1, 1, 6, 0]
        XCTAssertEqual(DOVIPacketRewriter.profile81ConfigurationRecordBytes(preserving: profile7Source),
                       [1, 0, 8, 6, 1, 0, 1, 1, 0])
        let eightByteSource: [UInt8] = [1, 0, 7, 9, 1, 1, 1, 6]
        XCTAssertEqual(DOVIPacketRewriter.profile81ConfigurationRecordBytes(preserving: eightByteSource),
                       [1, 0, 8, 9, 1, 0, 1, 1, 0])
        XCTAssertEqual(DOVIPacketRewriter.profile81ConfigurationRecordBytes(preserving: [UInt8]()),
                       [1, 0, 8, 0, 1, 0, 1, 1, 0])
    }

    func testProfile81ConfigurationRecordBytesFromRecord() {
        let record = DOVIDecoderConfigurationRecord(dv_version_major: 1,
                                                    dv_version_minor: 0,
                                                    dv_profile: 7,
                                                    dv_level: 6,
                                                    rpu_present_flag: 1,
                                                    el_present_flag: 1,
                                                    bl_present_flag: 1,
                                                    dv_bl_signal_compatibility_id: 6)
        XCTAssertEqual(DOVIPacketRewriter.profile81ConfigurationRecordBytes(preserving: record),
                       [1, 0, 8, 6, 1, 0, 1, 1, 0])
    }
}
