import Foundation
import Network

public protocol ProAVLocalServer: AnyObject {
    func start(rootDirectory: URL, completion: @escaping @Sendable (Result<URL, Error>) -> Void)
    func stop()
}

public final class ProAVLoopbackHTTPServer: ProAVLocalServer, @unchecked Sendable {
    private let queue = DispatchQueue(label: "Lumen.ProAVLoopbackHTTPServer")
    private var listener: NWListener?
    private var connections = [ObjectIdentifier: NWConnection]()
    private var rootDirectory: URL?
    private var pendingStartCompletion: (@Sendable (Result<URL, Error>) -> Void)?

    public init() {}

    public func start(rootDirectory: URL, completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.shutdownLocked()
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            let listener: NWListener
            do {
                listener = try NWListener(using: parameters)
            } catch {
                completion(.failure(error))
                return
            }
            self.rootDirectory = rootDirectory
            self.listener = listener
            self.pendingStartCompletion = completion
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, self.listener === listener else { return }
                switch state {
                case .ready:
                    if let port = listener.port, let url = URL(string: "http://127.0.0.1:\(port.rawValue)/") {
                        self.resolvePendingStart(.success(url))
                    } else {
                        self.resolvePendingStart(.failure(NSError(description: "ProAV loopback server has no port")))
                    }
                case let .failed(error):
                    self.resolvePendingStart(.failure(error))
                    self.queue.async { [weak self] in
                        guard let self, self.listener === listener else { return }
                        self.shutdownLocked()
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection: connection)
            }
            listener.start(queue: self.queue)
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.shutdownLocked()
        }
    }

    private func shutdownLocked() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        rootDirectory = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        resolvePendingStart(.failure(NSError(description: "ProAV loopback server stopped before it was ready")))
    }

    private func resolvePendingStart(_ result: Result<URL, Error>) {
        let completion = pendingStartCompletion
        pendingStartCompletion = nil
        completion?(result)
    }

    private func accept(connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .failed, .cancelled:
                self?.connections[ObjectIdentifier(connection)] = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection, buffered: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] content, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffered = buffered
            if let content {
                buffered.append(content)
            }
            if let headerEnd = buffered.range(of: Data("\r\n\r\n".utf8)) {
                let header = buffered.subdata(in: buffered.startIndex ..< headerEnd.lowerBound)
                self.handle(requestHeader: header, on: connection)
            } else if error != nil || isComplete || buffered.count > 65536 {
                connection.cancel()
            } else {
                self.receiveRequest(on: connection, buffered: buffered)
            }
        }
    }

    private func handle(requestHeader: Data, on connection: NWConnection) {
        guard let requestText = String(data: requestHeader, encoding: .utf8) else {
            send(header: Self.header(status: "400 Bad Request", contentType: nil, contentLength: 0, contentRange: nil), body: nil, on: connection)
            return
        }
        let lines = requestText.components(separatedBy: "\r\n")
        let requestParts = (lines.first ?? "").components(separatedBy: " ")
        guard requestParts.count >= 2, requestParts[0] == "GET" || requestParts[0] == "HEAD" else {
            send(header: Self.header(status: "405 Method Not Allowed", contentType: nil, contentLength: 0, contentRange: nil), body: nil, on: connection)
            return
        }
        let includeBody = requestParts[0] == "GET"
        guard let fileURL = fileURL(forRequestPath: requestParts[1]),
              let handle = try? FileHandle(forReadingFrom: fileURL)
        else {
            send(header: Self.header(status: "404 Not Found", contentType: nil, contentLength: 0, contentRange: nil), body: nil, on: connection)
            return
        }
        guard let fileSize = handle.proAVLength() else {
            handle.proAVClose()
            send(header: Self.header(status: "500 Internal Server Error", contentType: nil, contentLength: 0, contentRange: nil), body: nil, on: connection)
            return
        }
        let contentType = Self.contentType(forPathExtension: fileURL.pathExtension)
        var status = "200 OK"
        var start = UInt64(0)
        var length = fileSize
        var contentRange: String?
        if let byteRange = Self.byteRange(fromHeaderLines: lines) {
            let resolved = byteRange.resolve(fileSize: fileSize)
            if let resolved {
                status = "206 Partial Content"
                start = resolved.lowerBound
                length = resolved.upperBound - resolved.lowerBound + 1
                contentRange = "bytes \(resolved.lowerBound)-\(resolved.upperBound)/\(fileSize)"
            } else {
                handle.proAVClose()
                send(header: Self.header(status: "416 Range Not Satisfiable", contentType: nil, contentLength: 0, contentRange: "bytes */\(fileSize)"), body: nil, on: connection)
                return
            }
        }
        var body: Data?
        if includeBody {
            body = handle.proAVRead(offset: start, length: Int(length))
        }
        handle.proAVClose()
        if includeBody, body == nil {
            send(header: Self.header(status: "500 Internal Server Error", contentType: nil, contentLength: 0, contentRange: nil), body: nil, on: connection)
            return
        }
        let header = Self.header(status: status, contentType: contentType, contentLength: length, contentRange: contentRange)
        send(header: header, body: includeBody ? body : nil, on: connection)
    }

    private func fileURL(forRequestPath requestPath: String) -> URL? {
        guard let rootDirectory else { return nil }
        let rawPath = requestPath.components(separatedBy: "?").first ?? requestPath
        guard let decodedPath = rawPath.removingPercentEncoding, !decodedPath.contains("..") else { return nil }
        let relativePath = decodedPath.hasPrefix("/") ? String(decodedPath.dropFirst()) : decodedPath
        guard !relativePath.isEmpty else { return nil }
        let fileURL = rootDirectory.appendingPathComponent(relativePath)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return fileURL
    }

    private func send(header: String, body: Data?, on connection: NWConnection) {
        let receiveNextRequest = NWConnection.SendCompletion.contentProcessed { [weak self] error in
            if error != nil {
                connection.cancel()
            } else {
                self?.receiveRequest(on: connection, buffered: Data())
            }
        }
        guard let body, !body.isEmpty else {
            connection.send(content: Data(header.utf8), completion: receiveNextRequest)
            return
        }
        connection.send(content: Data(header.utf8), completion: .contentProcessed { error in
            if error != nil {
                connection.cancel()
            }
        })
        connection.send(content: body, completion: receiveNextRequest)
    }

    private static func header(status: String, contentType: String?, contentLength: UInt64, contentRange: String?) -> String {
        var lines = ["HTTP/1.1 \(status)"]
        if let contentType {
            lines.append("Content-Type: \(contentType)")
        }
        lines.append("Content-Length: \(contentLength)")
        lines.append("Accept-Ranges: bytes")
        if let contentRange {
            lines.append("Content-Range: \(contentRange)")
        }
        lines.append("Connection: keep-alive")
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    private static func contentType(forPathExtension pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "m3u8":
            return "application/vnd.apple.mpegurl"
        case "mp4", "m4s", "m4v":
            return "video/mp4"
        default:
            return "application/octet-stream"
        }
    }

    private enum ProAVByteRange {
        case bounded(UInt64, UInt64)
        case from(UInt64)
        case suffix(UInt64)

        func resolve(fileSize: UInt64) -> ClosedRange<UInt64>? {
            guard fileSize > 0 else { return nil }
            switch self {
            case let .bounded(start, end):
                guard start < fileSize, start <= end else { return nil }
                return start ... min(end, fileSize - 1)
            case let .from(start):
                guard start < fileSize else { return nil }
                return start ... (fileSize - 1)
            case let .suffix(count):
                guard count > 0 else { return nil }
                let start = count >= fileSize ? 0 : fileSize - count
                return start ... (fileSize - 1)
            }
        }
    }

    private static func byteRange(fromHeaderLines lines: [String]) -> ProAVByteRange? {
        for line in lines.dropFirst() {
            let lowercased = line.lowercased()
            guard lowercased.hasPrefix("range:") else { continue }
            guard let bytesMarker = lowercased.range(of: "bytes=") else { return nil }
            let specifier = lowercased[bytesMarker.upperBound...].components(separatedBy: ",").first ?? ""
            let bounds = specifier.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard bounds.count == 2 else { return nil }
            if bounds[0].isEmpty {
                guard let count = UInt64(bounds[1]) else { return nil }
                return .suffix(count)
            }
            guard let start = UInt64(bounds[0]) else { return nil }
            if bounds[1].isEmpty {
                return .from(start)
            }
            guard let end = UInt64(bounds[1]) else { return nil }
            return .bounded(start, end)
        }
        return nil
    }
}

extension FileHandle {
    func proAVLength() -> UInt64? {
        if #available(macOS 10.15.4, iOS 13.4, tvOS 13.4, *) {
            return try? seekToEnd()
        } else {
            return seekToEndOfFile()
        }
    }

    func proAVRead(offset: UInt64, length: Int) -> Data? {
        guard length >= 0 else { return nil }
        if #available(macOS 10.15.4, iOS 13.4, tvOS 13.4, *) {
            do {
                try seek(toOffset: offset)
                return try read(upToCount: length) ?? Data()
            } catch {
                return nil
            }
        } else {
            seek(toFileOffset: offset)
            return readData(ofLength: length)
        }
    }

    func proAVWrite(_ data: Data) -> Bool {
        if #available(macOS 10.15.4, iOS 13.4, tvOS 13.4, *) {
            do {
                try write(contentsOf: data)
                return true
            } catch {
                return false
            }
        } else {
            write(data)
            return true
        }
    }

    func proAVClose() {
        if #available(macOS 10.15.4, iOS 13.4, tvOS 13.4, *) {
            try? close()
        } else {
            closeFile()
        }
    }
}
