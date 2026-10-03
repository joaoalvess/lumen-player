import Foundation

public final class DiskCacheURLReader {
    private final class FetchBox {
        let semaphore = DispatchSemaphore(value: 0)
        let needed: Int
        var data = Data()
        var response: HTTPURLResponse?
        var isSatisfied = false
        var didFail = false

        init(needed: Int) {
            self.needed = needed
        }
    }

    private final class SessionDelegate: NSObject, URLSessionDataDelegate {
        private let lock = NSLock()
        private var boxes = [Int: FetchBox]()

        func register(box: FetchBox, for task: URLSessionTask) {
            lock.lock()
            defer { lock.unlock() }
            boxes[task.taskIdentifier] = box
        }

        private func box(for task: URLSessionTask) -> FetchBox? {
            lock.lock()
            defer { lock.unlock() }
            return boxes[task.taskIdentifier]
        }

        func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            box(for: dataTask)?.response = response as? HTTPURLResponse
            completionHandler(.allow)
        }

        func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard let box = box(for: dataTask), !box.isSatisfied else {
                return
            }
            box.data.append(data)
            if box.data.count >= box.needed {
                box.isSatisfied = true
                dataTask.cancel()
            }
        }

        func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            let box = boxes.removeValue(forKey: task.taskIdentifier)
            lock.unlock()
            guard let box else {
                return
            }
            if error != nil, !box.isSatisfied {
                box.didFail = true
            }
            box.semaphore.signal()
        }
    }

    private let cache: DiskByteCache
    private let url: URL
    private let headers: [String: String]
    private let chunkSize: Int
    private let session: URLSession
    private let sessionDelegate: SessionDelegate
    private let fetchLock = NSLock()
    private let stateLock = NSLock()
    private var currentTask: URLSessionDataTask?
    private var isClosed = false

    public init?(url: URL, directory: URL, key: String, maxBytes: Int64, headers: [String: String] = [:], chunkSize: Int = 1_048_576) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", chunkSize > 0 else {
            return nil
        }
        guard let cache = DiskByteCache(directory: directory, key: key, maxBytes: maxBytes) else {
            return nil
        }
        self.url = url
        self.cache = cache
        self.headers = headers
        self.chunkSize = chunkSize
        sessionDelegate = SessionDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration, delegate: sessionDelegate, delegateQueue: nil)
    }

    public var contentLength: Int64? {
        cache.contentLength
    }

    public var contentType: String? {
        cache.contentType
    }

    public func prepare() -> Bool {
        if cache.contentLength != nil {
            return true
        }
        _ = fetch(at: 0, requestLength: chunkSize)
        return cache.contentLength != nil
    }

    public func read(at offset: Int64, maxLength: Int) -> Data? {
        guard offset >= 0, maxLength > 0 else {
            return nil
        }
        if let total = cache.contentLength, offset >= total {
            return Data()
        }
        if let data = cache.cachedData(at: offset, maxLength: maxLength) {
            return data
        }
        guard let fetched = fetch(at: offset, requestLength: max(maxLength, chunkSize)) else {
            return nil
        }
        guard fetched.count > maxLength else {
            return fetched
        }
        return Data(fetched.prefix(maxLength))
    }

    public func close() {
        stateLock.lock()
        let alreadyClosed = isClosed
        isClosed = true
        let task = currentTask
        currentTask = nil
        stateLock.unlock()
        guard !alreadyClosed else {
            return
        }
        task?.cancel()
        session.invalidateAndCancel()
        cache.close()
    }

    deinit {
        close()
    }

    private func fetch(at offset: Int64, requestLength: Int) -> Data? {
        fetchLock.lock()
        defer { fetchLock.unlock() }
        if let data = cache.cachedData(at: offset, maxLength: requestLength) {
            return data
        }
        var length = Int64(requestLength)
        if let total = cache.contentLength {
            guard offset < total else {
                return Data()
            }
            length = min(length, total - offset)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
        let box = FetchBox(needed: Int(length))
        stateLock.lock()
        guard !isClosed else {
            stateLock.unlock()
            return nil
        }
        let task = session.dataTask(with: request)
        sessionDelegate.register(box: box, for: task)
        currentTask = task
        stateLock.unlock()
        task.resume()
        box.semaphore.wait()
        stateLock.lock()
        currentTask = nil
        let closed = isClosed
        stateLock.unlock()
        guard !closed, !box.didFail, let response = box.response else {
            return nil
        }
        switch response.statusCode {
        case 206:
            guard DiskCacheURLReader.isValidPartialResponse(contentRange: response.value(forHTTPHeaderField: "Content-Range"), offset: offset, bodyLength: box.data.count) else {
                return nil
            }
            if cache.contentLength == nil {
                cache.contentLength = DiskCacheURLReader.totalLength(of: response)
            }
            if cache.contentType == nil, let mimeType = response.mimeType {
                cache.contentType = mimeType
            }
            guard !box.data.isEmpty else {
                return Data()
            }
            cache.write(box.data, at: offset)
            return box.data
        case 416:
            if cache.contentLength == nil {
                cache.contentLength = DiskCacheURLReader.totalLength(of: response)
            }
            return Data()
        default:
            return nil
        }
    }

    private static func totalLength(of response: HTTPURLResponse) -> Int64? {
        guard let contentRange = response.value(forHTTPHeaderField: "Content-Range") else {
            return nil
        }
        let parts = contentRange.split(separator: "/")
        guard parts.count == 2, let total = Int64(parts[1]) else {
            return nil
        }
        return total
    }

    struct ContentRange: Equatable {
        let start: Int64
        let end: Int64
        let total: Int64?
    }

    static func parseContentRange(_ value: String) -> ContentRange? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes") else {
            return nil
        }
        let spec = trimmed.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " ="))
        let parts = spec.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return nil
        }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]), start >= 0, end >= start else {
            return nil
        }
        guard parts[1] != "*" else {
            return ContentRange(start: start, end: end, total: nil)
        }
        guard let total = Int64(parts[1]), total > end else {
            return nil
        }
        return ContentRange(start: start, end: end, total: total)
    }

    static func isValidPartialResponse(contentRange: String?, offset: Int64, bodyLength: Int) -> Bool {
        guard let contentRange, let range = parseContentRange(contentRange), range.start == offset else {
            return false
        }
        return Int64(bodyLength) - 1 <= range.end - range.start
    }
}
