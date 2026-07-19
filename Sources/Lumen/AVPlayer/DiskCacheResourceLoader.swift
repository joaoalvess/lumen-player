import AVFoundation
import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

public final class DiskCacheResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    private static let schemePrefix = "ksdiskcache-"
    private static let responseChunk = 512 * 1024
    public let delegateQueue = DispatchQueue(label: "Lumen.DiskCacheResourceLoader.delegate")
    private let workQueue = DispatchQueue(label: "Lumen.DiskCacheResourceLoader.data", qos: .userInitiated, attributes: .concurrent)
    private let reader: DiskCacheURLReader

    public init?(url: URL, directory: URL, key: String, maxBytes: Int64, headers: [String: String] = [:]) {
        guard DiskCacheResourceLoader.assetURL(for: url) != nil else {
            return nil
        }
        guard let reader = DiskCacheURLReader(url: url, directory: directory, key: key, maxBytes: maxBytes, headers: headers) else {
            return nil
        }
        self.reader = reader
        super.init()
    }

    public static func assetURL(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        let pathExtension = url.pathExtension.lowercased()
        guard pathExtension != "m3u8", pathExtension != "m3u" else {
            return nil
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = schemePrefix + scheme
        return components?.url
    }

    public static func originalURL(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme.hasPrefix(schemePrefix) else {
            return nil
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = String(scheme.dropFirst(schemePrefix.count))
        return components?.url
    }

    public func close() {
        reader.close()
    }

    public func resourceLoader(_: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        workQueue.async { [weak self] in
            self?.process(loadingRequest: loadingRequest)
        }
        return true
    }

    private func process(loadingRequest: AVAssetResourceLoadingRequest) {
        guard reader.prepare(), let total = reader.contentLength else {
            loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable))
            return
        }
        if let infoRequest = loadingRequest.contentInformationRequest {
            infoRequest.contentLength = total
            infoRequest.isByteRangeAccessSupported = true
            infoRequest.contentType = DiskCacheResourceLoader.contentType(mimeType: reader.contentType)
        }
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return
        }
        var offset = dataRequest.currentOffset
        var remaining: Int64
        if dataRequest.requestsAllDataToEndOfResource {
            remaining = total - offset
        } else {
            remaining = Int64(dataRequest.requestedLength) - (offset - dataRequest.requestedOffset)
        }
        remaining = min(remaining, total - offset)
        while remaining > 0 {
            if loadingRequest.isCancelled || loadingRequest.isFinished {
                return
            }
            let want = Int(min(Int64(DiskCacheResourceLoader.responseChunk), remaining))
            guard let data = reader.read(at: offset, maxLength: want), !data.isEmpty else {
                if !loadingRequest.isCancelled, !loadingRequest.isFinished {
                    loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost))
                }
                return
            }
            dataRequest.respond(with: data)
            offset += Int64(data.count)
            remaining -= Int64(data.count)
        }
        if !loadingRequest.isCancelled, !loadingRequest.isFinished {
            loadingRequest.finishLoading()
        }
    }

    private static func contentType(mimeType: String?) -> String {
        if let mimeType {
            #if canImport(UniformTypeIdentifiers)
            if #available(macOS 11.0, iOS 14.0, tvOS 14.0, macCatalyst 14.0, *) {
                if let type = UTType(mimeType: mimeType) {
                    return type.identifier
                }
            }
            #endif
            switch mimeType.lowercased() {
            case "video/mp4":
                return AVFileType.mp4.rawValue
            case "video/quicktime":
                return AVFileType.mov.rawValue
            case "video/mp2t":
                return "public.mpeg-2-transport-stream"
            case "audio/mpeg":
                return AVFileType.mp3.rawValue
            case "audio/mp4", "audio/x-m4a":
                return AVFileType.m4a.rawValue
            default:
                break
            }
        }
        return AVFileType.mp4.rawValue
    }
}
