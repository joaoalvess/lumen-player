import Foundation

enum ProAVHDR10PlusScanner {
    static let compatibleBrand = "cdm4"
    private static let prefixSEINALUnitType: UInt8 = 39
    private static let userDataRegisteredPayloadType = 4
    private static let countryCode: UInt8 = 0xB5
    private static let terminalProviderCode: UInt16 = 0x003C
    private static let terminalProviderOrientedCode: UInt16 = 0x0001
    private static let applicationIdentifier: UInt8 = 4
    private static let seiHeaderByteCount = 2

    static func containsHDR10Plus(payload: Data, nalLengthSize: Int) -> Bool {
        guard (1 ... 4).contains(nalLengthSize) else {
            return false
        }
        return payload.withUnsafeBytes { rawBuffer -> Bool in
            guard let bytes = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return false
            }
            let count = rawBuffer.count
            var offset = 0
            while offset + nalLengthSize <= count {
                var nalLength = 0
                for index in 0 ..< nalLengthSize {
                    nalLength = (nalLength << 8) | Int(bytes[offset + index])
                }
                let nalStart = offset + nalLengthSize
                guard nalLength > 0, nalStart + nalLength <= count else {
                    return false
                }
                offset = nalStart + nalLength
                guard nalLength > seiHeaderByteCount, (bytes[nalStart] >> 1) & 0x3F == prefixSEINALUnitType else {
                    continue
                }
                let rbsp = removingEmulationPrevention(bytes + nalStart + seiHeaderByteCount, count: nalLength - seiHeaderByteCount)
                if containsHDR10PlusMessage(rbsp: rbsp) {
                    return true
                }
            }
            return false
        }
    }

    private static func removingEmulationPrevention(_ bytes: UnsafePointer<UInt8>, count: Int) -> [UInt8] {
        var output = [UInt8]()
        output.reserveCapacity(count)
        var zeroRun = 0
        for index in 0 ..< count {
            let byte = bytes[index]
            if zeroRun >= 2, byte == 0x03 {
                zeroRun = 0
                continue
            }
            output.append(byte)
            zeroRun = byte == 0 ? zeroRun + 1 : 0
        }
        return output
    }

    private static func containsHDR10PlusMessage(rbsp: [UInt8]) -> Bool {
        var offset = 0
        while offset < rbsp.count {
            guard let payloadType = readExtendedValue(rbsp, from: offset),
                  let payloadSize = readExtendedValue(rbsp, from: payloadType.next)
            else {
                return false
            }
            let payloadStart = payloadSize.next
            guard payloadStart + payloadSize.value <= rbsp.count else {
                return false
            }
            if payloadType.value == userDataRegisteredPayloadType,
               matchesHDR10Plus(rbsp, at: payloadStart, size: payloadSize.value)
            {
                return true
            }
            offset = payloadStart + payloadSize.value
        }
        return false
    }

    private static func readExtendedValue(_ bytes: [UInt8], from offset: Int) -> (value: Int, next: Int)? {
        var value = 0
        var index = offset
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            value += Int(byte)
            if byte != 0xFF {
                return (value, index)
            }
            if value > 0xFFFF {
                return nil
            }
        }
        return nil
    }

    private static func matchesHDR10Plus(_ bytes: [UInt8], at offset: Int, size: Int) -> Bool {
        guard size >= 6, bytes[offset] == countryCode else {
            return false
        }
        let provider = (UInt16(bytes[offset + 1]) << 8) | UInt16(bytes[offset + 2])
        let oriented = (UInt16(bytes[offset + 3]) << 8) | UInt16(bytes[offset + 4])
        return provider == terminalProviderCode && oriented == terminalProviderOrientedCode && bytes[offset + 5] == applicationIdentifier
    }

    static func appendingCompatibleBrand(_ brand: String, toInitSegment initSegment: Data) -> Data? {
        let brandBytes = Array(brand.utf8)
        guard brandBytes.count == 4, initSegment.count >= 16 else {
            return nil
        }
        let base = initSegment.startIndex
        var boxSize = 0
        for index in 0 ..< 4 {
            boxSize = (boxSize << 8) | Int(initSegment[base + index])
        }
        guard boxSize >= 16, boxSize % 4 == 0, boxSize <= initSegment.count,
              initSegment.subdata(in: base + 4 ..< base + 8) == Data("ftyp".utf8),
              let updatedSize = UInt32(exactly: boxSize + 4)
        else {
            return nil
        }
        let brandData = Data(brandBytes)
        let alreadyCompatible = stride(from: 16, to: boxSize, by: 4).contains { start in
            initSegment.subdata(in: base + start ..< base + start + 4) == brandData
        }
        guard !alreadyCompatible else {
            return initSegment
        }
        var output = Data(capacity: initSegment.count + 4)
        output.append(contentsOf: withUnsafeBytes(of: updatedSize.bigEndian) { Array($0) })
        output.append(initSegment.subdata(in: base + 4 ..< base + boxSize))
        output.append(brandData)
        output.append(initSegment.subdata(in: base + boxSize ..< initSegment.endIndex))
        return output
    }
}
