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
    static let audioPlaylistName = "audio.m3u8"
    static let audioInitSegmentName = "audio-init.mp4"

    /// Which audio tracks of a launch try the APAC conversion before FLAC.
    struct SpatialAudioPolicy: Equatable {
        /// Tracks the library refused, which keep the FLAC path for their source.
        var refusedTrackIDs = Set<Int32>()
        /// Off for a launch that retries on FLAC after the conversion failed without refusing the track.
        var isEnabled = true
        var isExternalPlaybackActive = false

        func allows(trackID: Int32) -> Bool {
            isEnabled && !isExternalPlaybackActive && !refusedTrackIDs.contains(trackID)
        }
    }

    enum SpatialAudioFailure: Equatable {
        /// The library refused the track, as it does for TrueHD without Atmos or DTS-HD MA without DTS:X.
        case refused(trackID: Int32)
        /// The conversion failed for this launch only.
        case failed
    }

    let configuration: Configuration
    private let lock = NSLock()
    private var pendingEvents = [() -> Void]()
    private var _preferredAudioTrackID: Int32?
    private var _spatialAudioPolicy = SpatialAudioPolicy()
    private var _spatialAudioFailure: SpatialAudioFailure?
    private var _spatialAudioWithheld = false
    private var _playbackTime: TimeInterval?
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
    private var segments = [ProAVSegment]()
    private var audioSegments = [ProAVSegment]()
    private var segmentIndex = 0
    private var segmentStart: Double?
    private var lastVideoSeconds: Double?
    private var lastAudioSeconds: Double?
    private var audioEndSeconds: Double?
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

    var spatialAudioPolicy: SpatialAudioPolicy {
        get {
            withLock { _spatialAudioPolicy }
        }
        set {
            withLock { _spatialAudioPolicy = newValue }
        }
    }

    /// Whether the audio plays as the separate APAC rendition.
    var playsSpatialAudio: Bool {
        withLock { audioSignaling?.mediaPlaylistName != nil }
    }

    /// Set when the session failed because the APAC conversion did; the FLAC path can still play the track.
    var spatialAudioFailure: SpatialAudioFailure? {
        withLock { _spatialAudioFailure }
    }

    /// Whether this launch left APAC out for an eligible track that its source has not refused, as during
    /// AirPlay, so a later launch can bring it back.
    var spatialAudioWithheld: Bool {
        get {
            withLock { _spatialAudioWithheld }
        }
        set {
            withLock { _spatialAudioWithheld = newValue }
        }
    }

    /// Recheck after opening as well as on route changes: the route can change before audio is selected.
    func needsSpatialAudioRestart(isExternalPlaybackActive: Bool) -> Bool {
        withLock {
            isExternalPlaybackActive ? audioSignaling?.mediaPlaylistName != nil : _spatialAudioWithheld
        }
    }

    /// The player's position from the start of the file, which the remux reads ahead of.
    var playbackTime: TimeInterval? {
        get {
            withLock { _playbackTime }
        }
        set {
            withLock { _playbackTime = newValue }
        }
    }

    /// Pace the least advanced required stream so pausing the only reader cannot starve audio.
    /// Source timestamps start at `sourceStart`; playback counts from the start of the file.
    func remuxedAhead(sourceStart: TimeInterval) -> TimeInterval? {
        withLock {
            guard readyFired, let lastVideoSeconds, let _playbackTime else { return nil }
            if audioSignaling != nil {
                guard let lastAudioSeconds else { return nil }
                // Once all declared audio is read, its shorter duration must not make the video
                // tail read without a bound. Unknown ends still wait for audio to avoid starvation.
                if let audioEndSeconds, lastAudioSeconds >= audioEndSeconds - 0.000001 {
                    return lastVideoSeconds - sourceStart - _playbackTime
                }
                return min(lastVideoSeconds, lastAudioSeconds) - sourceStart - _playbackTime
            }
            return lastVideoSeconds - sourceStart - _playbackTime
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
                self.segmentStart = seconds
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

    func trackAudioTime(seconds: Double, duration: Double = 0, streamEnd: Double? = nil) {
        withLock {
            let end = seconds + max(duration, 0)
            lastAudioSeconds = max(lastAudioSeconds ?? end, end)
            audioEndSeconds = streamEnd
        }
    }

    func closeSegment(nextStartTime: Double) {
        withLock {
            guard let start = segmentStart else {
                segmentStart = nextStartTime
                return
            }
            completeCurrentSegmentLocked(duration: max(nextStartTime - start, 0.02))
            segmentStart = nextStartTime
            currentHandle = openFileLocked(named: segmentFileName(index: segmentIndex))
            currentSegmentBytes = 0
            writePlaylistsLocked(ended: false)
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
                } else if audioSignaling?.mediaPlaylistName != nil, audioSegments.isEmpty {
                    // The session could never become ready; the FLAC transcode can still play the track.
                    _spatialAudioFailure = .failed
                    failLocked(NSError(description: "ProAV spatial audio produced no fragments"))
                } else {
                    writePlaylistsLocked(ended: true)
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

    func failSpatialAudio(_ error: NSError, failure: SpatialAudioFailure) {
        withLock {
            guard !failed else { return }
            _spatialAudioFailure = failure
            failLocked(error)
        }
    }

    func writeAudioInitSegment(_ data: Data) {
        withLock {
            guard !finished, !failed else { return }
            writeLocked(data: data, named: Self.audioInitSegmentName)
        }
    }

    func appendAudioSegment(_ data: Data, duration: Double) {
        withLock {
            guard !finished, !failed else { return }
            let fileName = "audio\(audioSegments.count).m4s"
            writeLocked(data: data, named: fileName)
            guard !failed else { return }
            audioSegments.append(ProAVSegment(fileName: fileName, duration: duration))
            writePlaylistsLocked(ended: false)
            fireReadyIfNeededLocked(force: false)
        }
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
    }

    /// Writes the video playlist and the separate audio rendition's, which HLS requires to share one
    /// target duration, so a longer segment in either raises both.
    private func writePlaylistsLocked(ended: Bool) {
        let targetDuration = max(configuration.targetSegmentDuration, (segments + audioSegments).map(\.duration).max() ?? 0)
        let media = ProAVPlaylist.media(targetDuration: targetDuration, initSegmentName: Self.initSegmentName, segments: segments, ended: ended)
        writeLocked(text: media, to: mediaURL)
        guard audioSignaling?.mediaPlaylistName != nil else { return }
        let audio = ProAVPlaylist.media(targetDuration: targetDuration, initSegmentName: Self.audioInitSegmentName, segments: audioSegments, ended: ended)
        writeLocked(text: audio, to: configuration.directory.appendingPathComponent(Self.audioPlaylistName))
    }

    private func fireReadyIfNeededLocked(force: Bool) {
        guard !readyFired, !failed, !segments.isEmpty else { return }
        guard force || segments.count >= configuration.minimumSegmentsBeforeReady else { return }
        // A separate audio rendition needs a fragment too before the player can start.
        guard audioSignaling?.mediaPlaylistName == nil || !audioSegments.isEmpty else { return }
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

    private func writeLocked(data: Data, named name: String) {
        do {
            try data.write(to: configuration.directory.appendingPathComponent(name))
        } catch {
            failLocked(NSError(description: "ProAV segment write failed: \(name)"))
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
        guard initHandle.proAVWrite(initSegment) else {
            failLocked(NSError(description: "ProAV init segment write failed"))
            return false
        }
        initHandle.proAVClose()
        currentHandle = nil
        initBoundaryFound = true
        let master = ProAVPlaylist.master(mediaPlaylistName: Self.mediaPlaylistName, video: signaling, audio: audioSignaling, bandwidth: bandwidth, resolution: resolution, frameRate: frameRate)
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
