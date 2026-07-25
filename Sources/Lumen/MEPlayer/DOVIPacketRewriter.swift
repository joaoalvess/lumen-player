import Foundation
import Libavcodec
import Libdovi

enum DOVIPacketRewriteError: Error, Equatable {
    case unsupportedNALLengthSize
    case truncatedLengthPrefix
    case truncatedNALUnit
    case invalidNALUnitLength
    case oversizedNALUnit
    case emptyRewrittenPayload
    case rpuConversionFailed
    case missingPayload
    case oversizedPayload
    case allocationFailed
}

enum DOVIPacketRewriter {
    static let rpuNALUnitType: UInt8 = 62
    static let enhancementLayerNALUnitType: UInt8 = 63
    private static let profile81ConversionMode: UInt8 = 2

    static func hevcNALUnitLengthSize(hvcC: UnsafePointer<UInt8>?, size: Int32) -> Int? {
        guard let hvcC, size >= 23, hvcC[0] == 1 else {
            return nil
        }
        return Int(hvcC[21] & 0x03) + 1
    }

    static func rewrite(payload: Data, nalLengthSize: Int, transformRPUNALUnit: (Data) -> Data?) throws -> Data {
        guard (1 ... 4).contains(nalLengthSize) else {
            throw DOVIPacketRewriteError.unsupportedNALLengthSize
        }
        return try payload.withUnsafeBytes { rawBuffer -> Data in
            guard let bytes = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw DOVIPacketRewriteError.emptyRewrittenPayload
            }
            let count = rawBuffer.count
            let maxNALUnitLength = (1 << (8 * nalLengthSize)) - 1
            var output = Data(capacity: count)
            var wroteNALUnit = false
            var offset = 0
            while offset < count {
                guard offset + nalLengthSize <= count else {
                    throw DOVIPacketRewriteError.truncatedLengthPrefix
                }
                var nalLength = 0
                for index in 0 ..< nalLengthSize {
                    nalLength = (nalLength << 8) | Int(bytes[offset + index])
                }
                guard nalLength > 0 else {
                    throw DOVIPacketRewriteError.invalidNALUnitLength
                }
                let nalStart = offset + nalLengthSize
                guard nalStart + nalLength <= count else {
                    throw DOVIPacketRewriteError.truncatedNALUnit
                }
                let nalType = (bytes[nalStart] >> 1) & 0x3F
                offset = nalStart + nalLength
                if nalType == enhancementLayerNALUnitType {
                    continue
                }
                if nalType == rpuNALUnitType {
                    let nalUnit = Data(bytes: bytes + nalStart, count: nalLength)
                    guard let converted = transformRPUNALUnit(nalUnit), !converted.isEmpty else {
                        throw DOVIPacketRewriteError.rpuConversionFailed
                    }
                    guard converted.count <= maxNALUnitLength else {
                        throw DOVIPacketRewriteError.oversizedNALUnit
                    }
                    appendLengthPrefix(converted.count, nalLengthSize: nalLengthSize, to: &output)
                    output.append(converted)
                } else {
                    appendLengthPrefix(nalLength, nalLengthSize: nalLengthSize, to: &output)
                    output.append(bytes + nalStart, count: nalLength)
                }
                wroteNALUnit = true
            }
            guard wroteNALUnit else {
                throw DOVIPacketRewriteError.emptyRewrittenPayload
            }
            return output
        }
    }

    private static func appendLengthPrefix(_ length: Int, nalLengthSize: Int, to output: inout Data) {
        for shift in stride(from: (nalLengthSize - 1) * 8, through: 0, by: -8) {
            output.append(UInt8((length >> shift) & 0xFF))
        }
    }

    static func rewrite(packet: UnsafeMutablePointer<AVPacket>, nalLengthSize: Int) throws {
        let size = Int(packet.pointee.size)
        guard size > 0, let data = packet.pointee.data else {
            throw DOVIPacketRewriteError.missingPayload
        }
        let payload = Data(bytesNoCopy: data, count: size, deallocator: .none)
        let rewritten = try rewrite(payload: payload, nalLengthSize: nalLengthSize, transformRPUNALUnit: convertRPUNALUnitToProfile81)
        guard let rewrittenSize = Int32(exactly: rewritten.count) else {
            throw DOVIPacketRewriteError.oversizedPayload
        }
        var replacementOption = av_packet_alloc()
        guard let replacement = replacementOption else {
            throw DOVIPacketRewriteError.allocationFailed
        }
        defer { av_packet_free(&replacementOption) }
        guard av_new_packet(replacement, rewrittenSize) == 0 else {
            throw DOVIPacketRewriteError.allocationFailed
        }
        let copied = rewritten.withUnsafeBytes { rawBuffer -> Bool in
            guard let source = rawBuffer.baseAddress, let destination = replacement.pointee.data else {
                return false
            }
            memcpy(destination, source, rewritten.count)
            return true
        }
        guard copied else {
            throw DOVIPacketRewriteError.allocationFailed
        }
        guard av_packet_copy_props(replacement, packet) == 0 else {
            throw DOVIPacketRewriteError.allocationFailed
        }
        av_packet_unref(packet)
        av_packet_move_ref(packet, replacement)
    }

    static func convertRPUNALUnitToProfile81(_ nalUnit: Data) -> Data? {
        nalUnit.withUnsafeBytes { rawBuffer -> Data? in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            guard let opaque = dovi_parse_unspec62_nalu(base, rawBuffer.count) else {
                return nil
            }
            defer { dovi_rpu_free(opaque) }
            guard dovi_rpu_get_error(opaque) == nil else {
                return nil
            }
            guard dovi_convert_rpu_with_mode(opaque, profile81ConversionMode) == 0 else {
                return nil
            }
            guard let written = dovi_write_unspec62_nalu(opaque) else {
                return nil
            }
            defer { dovi_data_free(written) }
            guard let writtenBytes = written.pointee.data, written.pointee.len > 0 else {
                return nil
            }
            return Data(bytes: writtenBytes, count: written.pointee.len)
        }
    }

    static func profile81ConfigurationRecordBytes(preserving source: [UInt8]) -> [UInt8] {
        var record: [UInt8] = [1, 0, 8, 0, 1, 0, 1, 1, 0]
        for index in [0, 1, 3, 4, 6] where index < source.count {
            record[index] = source[index]
        }
        return record
    }

    static func profile81ConfigurationRecordBytes(preserving record: DOVIDecoderConfigurationRecord) -> [UInt8] {
        profile81ConfigurationRecordBytes(preserving: [record.dv_version_major,
                                                      record.dv_version_minor,
                                                      record.dv_profile,
                                                      record.dv_level,
                                                      record.rpu_present_flag,
                                                      record.el_present_flag,
                                                      record.bl_present_flag,
                                                      record.dv_bl_signal_compatibility_id])
    }
}
