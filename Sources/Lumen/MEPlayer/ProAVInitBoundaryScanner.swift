import Foundation

struct ProAVInitBoundaryScanner {
    enum Outcome: Equatable {
        case buffering
        case split(initSegment: Data, remainder: Data)
        case malformed
    }

    private static let fragmentBoxType = UInt64(0x6D6F_6F66)
    private static let bufferLimit = 8 * 1024 * 1024

    private var buffer = Data()
    private var parseOffset = 0

    mutating func consume(_ data: Data) -> Outcome {
        buffer.append(data)
        guard buffer.count <= Self.bufferLimit else {
            return .malformed
        }
        while buffer.count - parseOffset >= 8 {
            let compactSize = value(at: parseOffset, count: 4)
            let boxType = value(at: parseOffset + 4, count: 4)
            if boxType == Self.fragmentBoxType {
                guard parseOffset > 0 else { return .malformed }
                let initSegment = buffer.subdata(in: buffer.startIndex ..< buffer.startIndex + parseOffset)
                let remainder = buffer.subdata(in: buffer.startIndex + parseOffset ..< buffer.endIndex)
                buffer = Data()
                parseOffset = 0
                return .split(initSegment: initSegment, remainder: remainder)
            }
            let boxSize: UInt64
            if compactSize == 0 {
                return .malformed
            } else if compactSize == 1 {
                guard buffer.count - parseOffset >= 16 else { return .buffering }
                boxSize = value(at: parseOffset + 8, count: 8)
                guard boxSize >= 16 else { return .malformed }
            } else {
                guard compactSize >= 8 else { return .malformed }
                boxSize = compactSize
            }
            guard boxSize <= UInt64(buffer.count - parseOffset) else { return .buffering }
            parseOffset += Int(boxSize)
        }
        return .buffering
    }

    private func value(at offset: Int, count: Int) -> UInt64 {
        var result = UInt64(0)
        for index in offset ..< (offset + count) {
            result = (result << 8) | UInt64(buffer[buffer.startIndex + index])
        }
        return result
    }
}
