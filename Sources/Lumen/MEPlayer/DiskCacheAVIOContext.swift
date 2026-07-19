import FFmpegKit
import Foundation

public final class DiskCacheAVIOContext: AbstractAVIOContext {
    private static let avseekForce = Int32(0x20000)
    private let reader: DiskCacheURLReader
    private let length: Int64
    private var position = Int64(0)

    public static func canCache(url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        let pathExtension = url.pathExtension.lowercased()
        return pathExtension != "m3u8" && pathExtension != "m3u"
    }

    public init?(url: URL, directory: URL, key: String, maxBytes: Int64, headers: [String: String] = [:]) {
        guard let reader = DiskCacheURLReader(url: url, directory: directory, key: key, maxBytes: maxBytes, headers: headers) else {
            return nil
        }
        guard reader.prepare(), let length = reader.contentLength, length > 0 else {
            reader.close()
            return nil
        }
        self.reader = reader
        self.length = length
        super.init(bufferSize: 256 * 1024, writable: false)
    }

    override public func read(buffer: UnsafePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else {
            return AVError.invalidArgument.code
        }
        guard position < length else {
            return AVError.eof.code
        }
        guard let data = reader.read(at: position, maxLength: Int(size)) else {
            return swift_AVERROR(EIO)
        }
        guard !data.isEmpty else {
            return AVError.eof.code
        }
        data.copyBytes(to: UnsafeMutablePointer(mutating: buffer), count: data.count)
        position += Int64(data.count)
        return Int32(data.count)
    }

    override public func seek(offset: Int64, whence: Int32) -> Int64 {
        let target: Int64
        switch whence & ~DiskCacheAVIOContext.avseekForce {
        case SEEK_SET:
            target = offset
        case SEEK_CUR:
            target = position + offset
        case SEEK_END:
            target = length + offset
        default:
            return Int64(AVError.invalidArgument.code)
        }
        guard target >= 0, target <= length else {
            return Int64(AVError.invalidArgument.code)
        }
        position = target
        return target
    }

    override public func fileSize() -> Int64 {
        length
    }

    override public func close() {
        reader.close()
    }
}
