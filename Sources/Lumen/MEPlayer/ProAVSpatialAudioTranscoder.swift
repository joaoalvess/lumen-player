import CoreMedia
import Foundation
import Libavcodec
import Libavformat
#if canImport(SpatialAudioBridge)
import SpatialAudioBridge
#endif

/// Converts a TrueHD Atmos or DTS:X track to APAC, which the remux serves as a separate audio
/// rendition instead of the FLAC transcode. A probe before the launch keeps a track the library refuses
/// on FLAC; one the probe cannot judge fails the session as decoding starts, and the player then
/// plays it through the FLAC transcode.
///
/// The read thread hands packets over and blocks while the conversion is behind, so the remux runs at
/// its pace. Fragments are placed on the muxer's timeline once `begin(origin:videoStart:)` says where
/// the video landed; packets that arrive before then are held.
final class ProAVSpatialAudioTranscoder: @unchecked Sendable {
    private enum Input {
        case timeline(origin: CMTime, videoStart: CMTime)
        case packet(Data, time: CMTime?)
    }

    let streamIndex: Int
    let signaling: ProAVAudioSignaling
    private let timebase: Timebase
    private let queue: AsyncStream<Input>.Continuation
    private let capacity = DispatchSemaphore(value: 64)
    private let completion = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var cancelled = false
    private(set) var hasTimeline = false

    /// Returns nil below tvOS, iOS and macOS 26 and for any track other than 48 kHz TrueHD or DTS-HD
    /// Master Audio, which keep the FLAC path.
    init?(stream: UnsafeMutablePointer<AVStream>, session: ProAVRemuxSession) {
        #if canImport(SpatialAudioBridge)
        guard #available(macOS 26, iOS 26, tvOS 26, *),
              let codecpar = stream.pointee.codecpar,
              let codec = Self.codec(codecpar: codecpar.pointee)
        else {
            return nil
        }
        // The offline profile would hold the first fragment back for about 20 s of audio.
        let configuration = APACConfiguration(liveEncoding: true)
        guard let priming = try? configuration.encoderPrimingDuration() else {
            return nil
        }
        streamIndex = Int(stream.pointee.index)
        timebase = Timebase(stream.pointee.time_base)
        signaling = ProAVAudioSignaling(codecsAttribute: configuration.layout.apacCodecString, channels: "\(configuration.layout.channelCount)", mediaPlaylistName: ProAVRemuxSession.audioPlaylistName)
        let (inputs, queue) = AsyncStream.makeStream(of: Input.self)
        self.queue = queue
        Task.detached { [self] in
            await convert(inputs, codec: codec, configuration: configuration, priming: priming, session: session)
        }
        #else
        return nil
        #endif
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Places the audio on the muxer's timeline, which starts at `origin`, the first video decode
    /// time, and starts it with the first video frame at `videoStart`.
    func begin(origin: CMTime, videoStart: CMTime) {
        hasTimeline = true
        capacity.wait()
        queue.yield(.timeline(origin: origin, videoStart: videoStart))
    }

    /// The muxer's timeline for its first video packet: the muxer shifts it so that the packet decodes
    /// at zero, deriving a missing decode time from the reorder delay as it does. Nil without any time.
    static func timeline(pts: Int64, dts: Int64, duration: Int64, videoDelay: Int32, timebase: Timebase) -> (origin: CMTime, videoStart: CMTime)? {
        let start = pts == Int64.min ? dts : pts
        guard start != Int64.min else {
            return nil
        }
        let origin = dts == Int64.min ? start - Int64(videoDelay) * duration : dts
        return (timebase.cmtime(for: origin), timebase.cmtime(for: start))
    }

    func append(packet: UnsafeMutablePointer<AVPacket>) {
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return }
        let timestamp = packet.pointee.pts == Int64.min ? packet.pointee.dts : packet.pointee.pts
        let time = timestamp == Int64.min ? nil : timebase.cmtime(for: timestamp)
        capacity.wait()
        queue.yield(.packet(Data(bytes: data, count: Int(packet.pointee.size)), time: time))
    }

    /// Converts the rest and waits until the last fragment reached the session.
    func finish() {
        queue.finish()
        completion.wait()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        queue.finish()
    }

    /// Whether a track would convert on this system, given the chance.
    static func converts(codecpar: AVCodecParameters) -> Bool {
        #if canImport(SpatialAudioBridge)
        if #available(macOS 26, iOS 26, tvOS 26, *) {
            return codec(codecpar: codecpar) != nil
        }
        #endif
        return false
    }

    /// Why the library will never render the track, found by decoding about a second of it from its
    /// first sync point without encoding; nil when it renders or the probe cannot tell. Reads the
    /// demuxer onward from where it is.
    static func probeRefusal(stream: UnsafeMutablePointer<AVStream>, formatContext: UnsafeMutablePointer<AVFormatContext>) -> String? {
        #if canImport(SpatialAudioBridge)
        guard #available(macOS 26, iOS 26, tvOS 26, *),
              let codecpar = stream.pointee.codecpar,
              let codec = codec(codecpar: codecpar.pointee)
        else {
            return nil
        }
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let packet else { return nil }
        let timebase = Timebase(stream.pointee.time_base)
        var audio = Data()
        var start: CMTime?
        var bytesRead = 0
        // The video read around the audio counts as well, so a track without a sync point ends it.
        while bytesRead < 32 << 20, audio.count < 8 << 20, av_read_frame(formatContext, packet) == 0 {
            defer { av_packet_unref(packet) }
            bytesRead += Int(packet.pointee.size)
            guard packet.pointee.stream_index == stream.pointee.index, let bytes = packet.pointee.data, packet.pointee.size > 0 else { continue }
            let data = Data(bytes: bytes, count: Int(packet.pointee.size))
            guard !audio.isEmpty || codec.isSyncPoint(data) else { continue }
            let timestamp = packet.pointee.pts == Int64.min ? packet.pointee.dts : packet.pointee.pts
            if timestamp != Int64.min {
                let time = timebase.cmtime(for: timestamp)
                if let start, (time - start).seconds >= 1 {
                    break
                }
                start = start ?? time
            }
            audio += data
        }
        // Damaged audio is for the conversion to judge, which falls back for this launch only.
        guard case let .unsupported(reason)? = try? codec.probe(audio) else {
            return nil
        }
        return reason
        #else
        return nil
        #endif
    }

    #if canImport(SpatialAudioBridge)
    @available(macOS 26, iOS 26, tvOS 26, *)
    static func codec(codecpar: AVCodecParameters) -> SpatialAudioCodec? {
        guard codecpar.sample_rate == 48000 else {
            return nil
        }
        // FFmpeg reports some DTS:X presentations as plain DTS-HD MA, so every one is offered and the
        // library tells them apart by decoding. TrueHD goes by FFmpeg's Atmos label.
        switch codecpar.codec_id {
        case AV_CODEC_ID_TRUEHD where codecpar.profile == AV_PROFILE_TRUEHD_ATMOS:
            return .trueHDAtmos
        case AV_CODEC_ID_DTS where [AV_PROFILE_DTS_HD_MA, AV_PROFILE_DTS_HD_MA_X, AV_PROFILE_DTS_HD_MA_X_IMAX].contains(codecpar.profile):
            return .dtsX
        default:
            return nil
        }
    }

    @available(macOS 26, iOS 26, tvOS 26, *)
    private func convert(_ inputs: AsyncStream<Input>, codec: SpatialAudioCodec, configuration: APACConfiguration, priming: CMTime, session: ProAVRemuxSession) async {
        var transcoder: SpatialAudioTranscoder?
        var timeline: (origin: CMTime, start: CMTime)?
        var held = [(data: Data, time: CMTime?)]()
        var unstartedBytes = 0
        var failed = false
        // Any error ends the session at once, so the player restarts on the FLAC path; an unsupported
        // track stays there.
        func fail(_ error: Error) {
            failed = true
            guard !isCancelled else { return }
            session.failSpatialAudio(NSError(description: "ProAV spatial audio failed: \(error)"), failure: Self.failure(for: error, trackID: Int32(streamIndex)))
        }
        func append(_ data: Data, time: CMTime?) async throws {
            guard let timeline else {
                held.append((data, time))
                return
            }
            if transcoder == nil {
                // Decoding starts at a TrueHD major sync or a DTS core sync; earlier audio is discarded
                // and a later start is padded with silence, so the audio begins with the video.
                guard let time, codec.isSyncPoint(data) else { return }
                var settings = configuration
                settings.startTime = timeline.start
                settings.inputStartTime = time - timeline.origin
                transcoder = try SpatialAudioTranscoder(codec: codec, destination: .segments { segment in
                    switch segment.kind {
                    case .initialization:
                        session.writeAudioInitSegment(segment.data)
                    case .media:
                        guard let duration = segment.duration?.seconds, duration > 0 else {
                            throw SpatialAudioError.encoding("APAC fragment without a duration")
                        }
                        session.appendAudioSegment(segment.data, duration: duration)
                    }
                }, configuration: settings)
            }
            try await transcoder?.append(data, time: time.map { $0 - timeline.origin })
        }
        // A failed or cancelled conversion keeps draining, so the read thread never waits on it.
        for await input in inputs {
            defer { capacity.signal() }
            guard !failed, !isCancelled else { continue }
            do {
                switch input {
                case let .timeline(origin, videoStart):
                    // Fragments keep the encoder priming before the start, which cannot go below zero.
                    timeline = (origin, CMTimeMaximum(videoStart - origin, priming))
                    let waiting = held
                    held = []
                    for packet in waiting {
                        try await append(packet.data, time: packet.time)
                    }
                case let .packet(data, time):
                    // Audio held for the timeline or skipped to a sync point is bounded, so a stream that
                    // never starts the conversion falls back to FLAC instead of buffering the file.
                    if transcoder == nil {
                        unstartedBytes += data.count
                        guard unstartedBytes <= 8 << 20 else {
                            throw SpatialAudioError.source("No sync point or video timeline within 8 MB of audio")
                        }
                    }
                    try await append(data, time: time)
                }
            } catch {
                fail(error)
            }
        }
        if isCancelled {
            await transcoder?.cancel()
        } else if !failed {
            do {
                guard let transcoder else {
                    throw SpatialAudioError.source("The track has no sync point to start from")
                }
                _ = try await transcoder.finish()
            } catch {
                fail(error)
            }
        }
        completion.signal()
    }

    /// How the player responds: an unsupported track keeps FLAC for its source, and anything else
    /// falls back for this launch only. That includes a discontinuity: its point lies ahead of
    /// playback, so restarting the launch would meet it again, and the next seek starts a new session.
    @available(macOS 26, iOS 26, tvOS 26, *)
    static func failure(for error: Error, trackID: Int32) -> ProAVRemuxSession.SpatialAudioFailure {
        if case .unsupported? = error as? SpatialAudioError {
            return .refused(trackID: trackID)
        }
        return .failed
    }
    #endif
}
