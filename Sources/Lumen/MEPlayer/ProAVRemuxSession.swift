import CoreGraphics
import Foundation
import Libavformat

public final class ProAVRemuxSession: @unchecked Sendable {
    public struct Configuration {
        public var directory: URL
        public var targetSegmentDuration: TimeInterval
        public var minimumSegmentsBeforeReady: Int
        public init(directory: URL, targetSegmentDuration: TimeInterval = 2, minimumSegmentsBeforeReady: Int = 2) {
            self.directory = directory
            self.targetSegmentDuration = targetSegmentDuration
            self.minimumSegmentsBeforeReady = minimumSegmentsBeforeReady
        }
    }

    static let masterPlaylistName = "master.m3u8"
    static let mediaPlaylistName = "media.m3u8"
    static let initSegmentName = "init.mp4"

    let configuration: Configuration
    private let lock = NSLock()
    private let progressLock = NSLock()
    private var _closedDuration = TimeInterval(0)
    private var _playlistStartSeconds: Double?
    private var pendingEvents = [() -> Void]()
    private var _preferredAudioTrackID: Int32?
    private var _onReady: ((URL) -> Void)?
    private var _onFailure: ((NSError) -> Void)?
    private var _videoSignaling: ProAVVideoSignaling?
    private var audioSignaling: ProAVAudioSignaling?
    private var bandwidth = Int64(0)
    private var resolution = CGSize.zero
    private var frameRate = Float(0)
    private var currentHandle: FileHandle?
    private var initScanner = ProAVInitBoundaryScanner()
    private var initBoundaryFound = false
    private var dynamicHDR10PlusDetected = false
    private var segments = [ProAVSegment]()
    private var segmentIndex = 0
    private var segmentStart: Double?
    private var lastVideoSeconds: Double?
    private var currentSegmentBytes = Int64(0)
    private var readyFired = false
    private var finished = false
    private var failed = false
    private var cleanupWhenFinished = false
    private var ioContext: UnsafeMutablePointer<AVIOContext>?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    var masterURL: URL {
        configuration.directory.appendingPathComponent(Self.masterPlaylistName)
    }

    private var mediaURL: URL {
        configuration.directory.appendingPathComponent(Self.mediaPlaylistName)
    }

    var preferredAudioTrackID: Int32? {
        get {
            withLock { _preferredAudioTrackID }
        }
        set {
            withLock { _preferredAudioTrackID = newValue }
        }
    }

    var onReady: ((URL) -> Void)? {
        get {
            withLock { _onReady }
        }
        set {
            withLock { _onReady = newValue }
        }
    }

    var onFailure: ((NSError) -> Void)? {
        get {
            withLock { _onFailure }
        }
        set {
            withLock { _onFailure = newValue }
        }
    }

    var videoSignaling: ProAVVideoSignaling? {
        withLock { _videoSignaling }
    }

    var closedSegmentsDuration: TimeInterval {
        progressLock.lock()
        defer { progressLock.unlock() }
        return _closedDuration
    }

    var playlistStartSeconds: Double? {
        progressLock.lock()
        defer { progressLock.unlock() }
        return _playlistStartSeconds
    }

    func begin(signaling: ProAVVideoSignaling, audioSignaling: ProAVAudioSignaling?, bandwidth: Int64, resolution: CGSize, frameRate: Float) -> Bool {
        withLock {
            _videoSignaling = signaling
            self.audioSignaling = audioSignaling
            self.bandwidth = bandwidth
            self.resolution = resolution
            self.frameRate = frameRate
            do {
                try FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
            } catch {
                failLocked(NSError(description: "ProAV workspace create failed: \(error.localizedDescription)"))
                return false
            }
            guard let handle = openFileLocked(named: Self.initSegmentName) else { return false }
            currentHandle = handle
            currentSegmentBytes = 0
            return true
        }
    }

    func noteDynamicHDR10Plus() {
        withLock {
            guard !initBoundaryFound else { return }
            dynamicHDR10PlusDetected = true
        }
    }

    func makeIOContext() -> UnsafeMutablePointer<AVIOContext>? {
        withLock {
            releaseIOContextLocked()
            let bufferSize = Int32(64 * 1024)
            let context = avio_alloc_context(av_malloc(Int(bufferSize)), bufferSize, 1, Unmanaged.passUnretained(self).toOpaque(), nil, { opaque, buffer, size -> Int32 in
                guard let opaque else { return -1 }
                let session = Unmanaged<ProAVRemuxSession>.fromOpaque(opaque).takeUnretainedValue()
                return session.write(buffer: buffer, size: size)
            }, { _, _, _ -> Int64 in
                -1
            })
            context?.pointee.seekable = 0
            ioContext = context
            return context
        }
    }

    func releaseIOContext() {
        withLock { releaseIOContextLocked() }
    }

    func shouldCutSegment(at seconds: Double) -> Bool {
        withLock {
            guard let segmentStart else {
                beginTimelineLocked(at: seconds)
                return false
            }
            return seconds - segmentStart >= configuration.targetSegmentDuration
        }
    }

    func trackVideoTime(seconds: Double) {
        withLock {
            if let lastVideoSeconds {
                if seconds > lastVideoSeconds {
                    self.lastVideoSeconds = seconds
                }
            } else {
                lastVideoSeconds = seconds
            }
        }
    }

    func closeSegment(nextStartTime: Double) {
        withLock {
            guard let start = segmentStart else {
                beginTimelineLocked(at: nextStartTime)
                return
            }
            completeCurrentSegmentLocked(duration: max(nextStartTime - start, 0.02))
            segmentStart = nextStartTime
            currentHandle = openFileLocked(named: segmentFileName(index: segmentIndex))
            currentSegmentBytes = 0
            writeMediaPlaylistLocked(ended: false)
            fireReadyIfNeededLocked(force: false)
        }
    }

    func finish(reachedEnd: Bool) {
        withLock {
            guard !finished else {
                cleanupIfRequestedLocked()
                return
            }
            finished = true
            if currentSegmentBytes > 0, let start = segmentStart {
                let end = lastVideoSeconds ?? start
                completeCurrentSegmentLocked(duration: max(end - start, 0.02))
            } else {
                currentHandle?.proAVClose()
                currentHandle = nil
            }
            if reachedEnd, !failed {
                if segments.isEmpty {
                    failLocked(NSError(description: "ProAV remux produced no segments"))
                } else {
                    writeMediaPlaylistLocked(ended: true)
                    fireReadyIfNeededLocked(force: true)
                }
            }
            cleanupIfRequestedLocked()
        }
    }

    var isFailed: Bool {
        withLock { failed }
    }

    func fail(_ error: NSError) {
        withLock { failLocked(error) }
    }

    func requestCleanup() {
        withLock {
            cleanupWhenFinished = true
            if finished {
                cleanupIfRequestedLocked()
            }
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        let result = body()
        let events = pendingEvents
        pendingEvents = []
        lock.unlock()
        events.forEach { $0() }
        return result
    }

    private func releaseIOContextLocked() {
        guard ioContext != nil else { return }
        if let buffer = ioContext?.pointee.buffer {
            av_free(buffer)
            ioContext?.pointee.buffer = nil
        }
        avio_context_free(&ioContext)
    }

    private func cleanupIfRequestedLocked() {
        guard cleanupWhenFinished else { return }
        try? FileManager.default.removeItem(at: configuration.directory)
    }

    private func beginTimelineLocked(at seconds: Double) {
        segmentStart = seconds
        progressLock.lock()
        _playlistStartSeconds = seconds
        progressLock.unlock()
    }

    private func segmentFileName(index: Int) -> String {
        "segment\(index).m4s"
    }

    private func openFileLocked(named name: String) -> FileHandle? {
        let url = configuration.directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            failLocked(NSError(description: "ProAV segment open failed: \(name)"))
            return nil
        }
        return handle
    }

    private func completeCurrentSegmentLocked(duration: Double) {
        currentHandle?.proAVClose()
        currentHandle = nil
        segments.append(ProAVSegment(fileName: segmentFileName(index: segmentIndex), duration: duration))
        segmentIndex += 1
        progressLock.lock()
        _closedDuration += duration
        progressLock.unlock()
    }

    private func writeMediaPlaylistLocked(ended: Bool) {
        let media = ProAVPlaylist.media(targetDuration: configuration.targetSegmentDuration, initSegmentName: Self.initSegmentName, segments: segments, ended: ended)
        writeLocked(text: media, to: mediaURL)
    }

    private func fireReadyIfNeededLocked(force: Bool) {
        guard !readyFired, !failed, !segments.isEmpty else { return }
        guard force || segments.count >= configuration.minimumSegmentsBeforeReady else { return }
        readyFired = true
        if let handler = _onReady {
            let url = masterURL
            pendingEvents.append { handler(url) }
        }
    }

    private func failLocked(_ error: NSError) {
        guard !failed else { return }
        failed = true
        if let handler = _onFailure {
            pendingEvents.append { handler(error) }
        }
    }

    private func writeLocked(text: String, to url: URL) {
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            failLocked(NSError(description: "ProAV playlist write failed: \(error.localizedDescription)"))
        }
    }

    private func write(buffer: UnsafePointer<UInt8>?, size: Int32) -> Int32 {
        withLock {
            guard let buffer, size > 0 else { return size }
            guard !failed else { return size }
            let data = Data(bytes: buffer, count: Int(size))
            if !initBoundaryFound {
                switch initScanner.consume(data) {
                case .buffering:
                    return size
                case .malformed:
                    failLocked(NSError(description: "ProAV init segment boundary not found"))
                    return -1
                case let .split(initSegment, remainder):
                    return completeInitSegmentLocked(initSegment: initSegment, remainder: remainder) ? size : -1
                }
            }
            guard let currentHandle else {
                failLocked(NSError(description: "ProAV segment handle missing"))
                return -1
            }
            guard currentHandle.proAVWrite(data) else {
                failLocked(NSError(description: "ProAV segment write failed"))
                return -1
            }
            currentSegmentBytes += Int64(size)
            return size
        }
    }

    private func completeInitSegmentLocked(initSegment: Data, remainder: Data) -> Bool {
        guard let signaling = _videoSignaling else {
            failLocked(NSError(description: "ProAV signaling missing"))
            return false
        }
        guard let initHandle = currentHandle else {
            failLocked(NSError(description: "ProAV init segment handle missing"))
            return false
        }
        let effectiveSignaling = dynamicHDR10PlusDetected ? signaling.addingDynamicHDR10Plus() : signaling
        let effectiveInitSegment = effectiveSignaling.supplementalCodecs == signaling.supplementalCodecs
            ? initSegment
            : ProAVHDR10PlusScanner.appendingCompatibleBrand(ProAVHDR10PlusScanner.compatibleBrand, toInitSegment: initSegment) ?? initSegment
        guard initHandle.proAVWrite(effectiveInitSegment) else {
            failLocked(NSError(description: "ProAV init segment write failed"))
            return false
        }
        initHandle.proAVClose()
        currentHandle = nil
        initBoundaryFound = true
        let master = ProAVPlaylist.master(mediaPlaylistName: Self.mediaPlaylistName, video: effectiveSignaling, audio: audioSignaling, bandwidth: bandwidth, resolution: resolution, frameRate: frameRate)
        writeLocked(text: master, to: masterURL)
        guard !failed else { return false }
        guard let segmentHandle = openFileLocked(named: segmentFileName(index: segmentIndex)) else { return false }
        currentHandle = segmentHandle
        currentSegmentBytes = 0
        guard remainder.isEmpty || segmentHandle.proAVWrite(remainder) else {
            failLocked(NSError(description: "ProAV segment write failed"))
            return false
        }
        currentSegmentBytes += Int64(remainder.count)
        return true
    }
}
