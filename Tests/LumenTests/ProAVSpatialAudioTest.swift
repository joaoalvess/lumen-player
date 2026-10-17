import CoreMedia
import FFmpegKit
import Libavcodec
import Libavformat
@testable import Lumen
#if canImport(SpatialAudioBridge)
import SpatialAudioBridge
#endif
import XCTest

class ProAVSpatialAudioTest: XCTestCase {
    private let apac = ProAVAudioSignaling(codecsAttribute: "apac.31.03", channels: "12", mediaPlaylistName: ProAVRemuxSession.audioPlaylistName)
    private let video = ProAVVideoSignaling(codecTag: "avc1", codecsAttribute: "avc1.640028", videoRange: "SDR", supplementalCodecs: nil, preferredDynamicRange: .sdr)

    private func makeSession() -> ProAVRemuxSession {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ProAVRemuxSession(configuration: .init(directory: directory))
    }

    func testMasterPointsAtTheAPACRendition() {
        let video = ProAVVideoSignaling(codecTag: "dvh1", codecsAttribute: "dvh1.08.06", videoRange: "PQ", supplementalCodecs: nil, preferredDynamicRange: .dolbyVision)
        let master = ProAVPlaylist.master(mediaPlaylistName: "media.m3u8", video: video, audio: apac, bandwidth: 24_000_000, resolution: CGSize(width: 3840, height: 2160), frameRate: 23.976)
        XCTAssertTrue(master.contains("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"main\",NAME=\"Original\",DEFAULT=YES,AUTOSELECT=YES,CHANNELS=\"12\",URI=\"audio.m3u8\"\n"))
        XCTAssertTrue(master.contains("CODECS=\"dvh1.08.06,apac.31.03\""))
        XCTAssertTrue(master.contains("AUDIO=\"main\""))
    }

    func testOnlyAtmosTrueHDAndLosslessDTSAreOffered() throws {
        #if canImport(SpatialAudioBridge)
        guard #available(macOS 26, iOS 26, tvOS 26, *) else {
            throw XCTSkip("SpatialAudioBridge requires macOS, iOS or tvOS 26")
        }
        func codec(_ codecID: AVCodecID, profile: Int32, sampleRate: Int32 = 48000) -> SpatialAudioCodec? {
            var codecpar = AVCodecParameters()
            codecpar.codec_id = codecID
            codecpar.profile = profile
            codecpar.sample_rate = sampleRate
            return ProAVSpatialAudioTranscoder.codec(codecpar: codecpar)
        }
        XCTAssertEqual(codec(AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_TRUEHD_ATMOS), .trueHDAtmos)
        XCTAssertNil(codec(AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_UNKNOWN))
        for profile in [AV_PROFILE_DTS_HD_MA, AV_PROFILE_DTS_HD_MA_X, AV_PROFILE_DTS_HD_MA_X_IMAX] {
            XCTAssertEqual(codec(AV_CODEC_ID_DTS, profile: profile), .dtsX)
        }
        for profile in [AV_PROFILE_DTS, AV_PROFILE_DTS_HD_HRA, AV_PROFILE_DTS_EXPRESS, AV_PROFILE_UNKNOWN] {
            XCTAssertNil(codec(AV_CODEC_ID_DTS, profile: profile))
        }
        XCTAssertNil(codec(AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_TRUEHD_ATMOS, sampleRate: 96000))
        XCTAssertNil(codec(AV_CODEC_ID_EAC3, profile: AV_PROFILE_EAC3_DDP_ATMOS))
        #else
        throw XCTSkip("SpatialAudioBridge is unavailable on this platform")
        #endif
    }

    func testOnlyUnsupportedTracksAreRefused() throws {
        #if canImport(SpatialAudioBridge)
        guard #available(macOS 26, iOS 26, tvOS 26, *) else {
            throw XCTSkip("SpatialAudioBridge requires macOS, iOS or tvOS 26")
        }
        XCTAssertEqual(ProAVSpatialAudioTranscoder.failure(for: SpatialAudioError.unsupported("This TrueHD stream has no Atmos presentation"), trackID: 1), .refused(trackID: 1))
        // A discontinuity lies ahead of playback, so like a transient error it falls back for the launch.
        let launchOnly: [Error] = [
            SpatialAudioError.discontinuity("Timestamps jumped"),
            SpatialAudioError.decoding("Atmos presentation has no object metadata within 0.5 s"),
            SpatialAudioError.encoding("APAC encoder stopped"),
            SpatialAudioError.source("No sync point or video timeline within 8 MB of audio"),
            SpatialAudioError.coreMedia(-12780),
            CancellationError(),
        ]
        for error in launchOnly {
            XCTAssertEqual(ProAVSpatialAudioTranscoder.failure(for: error, trackID: 1), .failed, "\(error)")
        }
        #else
        throw XCTSkip("SpatialAudioBridge is unavailable on this platform")
        #endif
    }

    func testTimelineFollowsTheMuxerShift() {
        let timebase = Timebase(num: 1, den: 1000)
        let demuxed = ProAVSpatialAudioTranscoder.timeline(pts: 1080, dts: 1000, duration: 40, videoDelay: 2, timebase: timebase)
        XCTAssertEqual(demuxed?.origin, CMTime(value: 1000, timescale: 1000))
        XCTAssertEqual(demuxed?.videoStart, CMTime(value: 1080, timescale: 1000))
        // The first packet after a seek has no decode time, so the muxer derives it from the B-frame delay.
        let afterSeek = ProAVSpatialAudioTranscoder.timeline(pts: 1000, dts: Int64.min, duration: 40, videoDelay: 2, timebase: timebase)
        XCTAssertEqual(afterSeek?.origin, CMTime(value: 920, timescale: 1000))
        XCTAssertEqual(afterSeek?.videoStart, CMTime(value: 1000, timescale: 1000))
        let withoutReordering = ProAVSpatialAudioTranscoder.timeline(pts: 1000, dts: Int64.min, duration: 40, videoDelay: 0, timebase: timebase)
        XCTAssertEqual(withoutReordering?.origin, CMTime(value: 1000, timescale: 1000))
        let decodeTimeOnly = ProAVSpatialAudioTranscoder.timeline(pts: Int64.min, dts: 500, duration: 40, videoDelay: 0, timebase: timebase)
        XCTAssertEqual(decodeTimeOnly?.origin, CMTime(value: 500, timescale: 1000))
        XCTAssertEqual(decodeTimeOnly?.videoStart, CMTime(value: 500, timescale: 1000))
        XCTAssertNil(ProAVSpatialAudioTranscoder.timeline(pts: Int64.min, dts: Int64.min, duration: 40, videoDelay: 2, timebase: timebase))
    }

    func testConversionThatNeverStartsFallsBackForTheLaunch() throws {
        #if canImport(SpatialAudioBridge)
        guard #available(macOS 26, iOS 26, tvOS 26, *) else {
            throw XCTSkip("SpatialAudioBridge requires macOS, iOS or tvOS 26")
        }
        let formatContext = avformat_alloc_context()
        defer { avformat_free_context(formatContext) }
        let stream = try XCTUnwrap(avformat_new_stream(formatContext, nil))
        stream.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        stream.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_TRUEHD
        stream.pointee.codecpar.pointee.profile = AV_PROFILE_TRUEHD_ATMOS
        stream.pointee.codecpar.pointee.sample_rate = 48000
        stream.pointee.time_base = AVRational(num: 1, den: 1000)
        let session = makeSession()
        let transcoder = try XCTUnwrap(ProAVSpatialAudioTranscoder(stream: stream, session: session))
        defer { transcoder.cancel() }
        transcoder.begin(origin: .zero, videoStart: .zero)
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let corePacket = try XCTUnwrap(packet)
        XCTAssertEqual(av_new_packet(corePacket, 64 * 1024), 0)
        memset(corePacket.pointee.data, 0, 64 * 1024)
        // 130 packets of 64 KB without a TrueHD major sync pass the 8 MB bound.
        for index in 0 ..< 130 {
            corePacket.pointee.pts = Int64(index) * 50
            transcoder.append(packet: corePacket)
        }
        let deadline = Date(timeIntervalSinceNow: 10)
        while !session.isFailed, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertEqual(session.spatialAudioFailure, .failed)
        #else
        throw XCTSkip("SpatialAudioBridge is unavailable on this platform")
        #endif
    }

    func testReadyWaitsForTheAPACRendition() throws {
        let session = makeSession()
        var readyCount = 0
        session.onReady = { _ in readyCount += 1 }
        XCTAssertTrue(session.begin(signaling: video, audioSignaling: apac, bandwidth: 12_000_000, resolution: CGSize(width: 1920, height: 1080), frameRate: 23.976))
        XCTAssertTrue(session.playsSpatialAudio)
        for start in [0.0, 2, 4] {
            session.closeSegment(nextStartTime: start)
        }
        XCTAssertEqual(readyCount, 0)
        session.writeAudioInitSegment(Data([0]))
        session.appendAudioSegment(Data([1]), duration: 3.2)
        XCTAssertEqual(readyCount, 1)
        session.finish(reachedEnd: true)
        let directory = session.configuration.directory
        let playlist = try String(contentsOf: directory.appendingPathComponent(ProAVRemuxSession.audioPlaylistName), encoding: .utf8)
        XCTAssertTrue(playlist.contains("#EXT-X-MAP:URI=\"audio-init.mp4\"\n#EXTINF:3.20000,\naudio0.m4s\n#EXT-X-ENDLIST\n"))
        // HLS requires the audio and video playlists of a variant to share one target duration.
        let media = try String(contentsOf: directory.appendingPathComponent(ProAVRemuxSession.mediaPlaylistName), encoding: .utf8)
        XCTAssertTrue(playlist.contains("#EXT-X-TARGETDURATION:4\n"))
        XCTAssertTrue(media.contains("#EXT-X-TARGETDURATION:4\n"))
    }

    func testEndingWithoutAPACFragmentsFallsBackForTheLaunch() {
        let session = makeSession()
        XCTAssertTrue(session.begin(signaling: video, audioSignaling: apac, bandwidth: 12_000_000, resolution: CGSize(width: 1920, height: 1080), frameRate: 23.976))
        session.closeSegment(nextStartTime: 0)
        session.closeSegment(nextStartTime: 2)
        session.finish(reachedEnd: true)
        XCTAssertTrue(session.isFailed)
        XCTAssertEqual(session.spatialAudioFailure, .failed)
    }

    func testOnlySpatialAudioFailuresFallBackToFLAC() {
        let failed = makeSession()
        failed.fail(NSError(description: "segment write failed"))
        failed.failSpatialAudio(NSError(description: "unsupported metadata"), failure: .refused(trackID: 1))
        XCTAssertTrue(failed.isFailed)
        XCTAssertNil(failed.spatialAudioFailure)
        let refused = makeSession()
        refused.failSpatialAudio(NSError(description: "unsupported metadata"), failure: .refused(trackID: 1))
        XCTAssertTrue(refused.isFailed)
        XCTAssertEqual(refused.spatialAudioFailure, .refused(trackID: 1))
    }

    func testRefusedTracksKeepFLACWhileOthersTryAPAC() {
        var policy = ProAVRemuxSession.SpatialAudioPolicy(refusedTrackIDs: [1])
        XCTAssertFalse(policy.allows(trackID: 1))
        XCTAssertTrue(policy.allows(trackID: 2))
        policy.isEnabled = false
        XCTAssertFalse(policy.allows(trackID: 2))
    }

    func testAirPlayPreservesConversionIntentAndRefusedTracks() {
        var policy = ProAVRemuxSession.SpatialAudioPolicy(refusedTrackIDs: [1])
        policy.isExternalPlaybackActive = true
        XCTAssertFalse(policy.allows(trackID: 2))
        policy.isExternalPlaybackActive = false
        XCTAssertTrue(policy.allows(trackID: 2))
        XCTAssertFalse(policy.allows(trackID: 1))
        policy.isEnabled = false
        policy.isExternalPlaybackActive = true
        policy.isExternalPlaybackActive = false
        XCTAssertFalse(policy.allows(trackID: 2))
    }

    func testOpeningLaunchRechecksAirPlayAfterAudioIsSelected() {
        let session = makeSession()
        XCTAssertFalse(session.needsSpatialAudioRestart(isExternalPlaybackActive: true))
        XCTAssertTrue(session.begin(signaling: video, audioSignaling: apac, bandwidth: 12_000_000, resolution: CGSize(width: 1920, height: 1080), frameRate: 23.976))
        XCTAssertTrue(session.needsSpatialAudioRestart(isExternalPlaybackActive: true))
        XCTAssertFalse(session.needsSpatialAudioRestart(isExternalPlaybackActive: false))
        session.finish(reachedEnd: false)
    }

    func testAirPlayWithheldLaunchRetriesOnTheLocalRoute() {
        let session = makeSession()
        let flac = ProAVAudioSignaling(codecsAttribute: "fLaC", channels: "8")
        XCTAssertTrue(session.begin(signaling: video, audioSignaling: flac, bandwidth: 12_000_000, resolution: CGSize(width: 1920, height: 1080), frameRate: 23.976))
        XCTAssertFalse(session.needsSpatialAudioRestart(isExternalPlaybackActive: false))
        session.spatialAudioWithheld = true
        XCTAssertTrue(session.needsSpatialAudioRestart(isExternalPlaybackActive: false))
        XCTAssertFalse(session.needsSpatialAudioRestart(isExternalPlaybackActive: true))
        session.finish(reachedEnd: false)
    }

    func testReadAheadWaitsForBothVideoAndAudio() {
        let flac = ProAVAudioSignaling(codecsAttribute: "fLaC", channels: "8")
        for audio in [apac, flac] {
            let session = makeSession()
            XCTAssertTrue(session.begin(signaling: video, audioSignaling: audio, bandwidth: 12_000_000, resolution: CGSize(width: 1920, height: 1080), frameRate: 23.976))
            session.playbackTime = 600
            session.trackVideoTime(seconds: 641.4)
            for start in [600.0, 602, 604] {
                session.closeSegment(nextStartTime: start)
            }
            if audio.mediaPlaylistName != nil {
                session.writeAudioInitSegment(Data([0]))
                session.appendAudioSegment(Data([1]), duration: 3.2)
            }
            XCTAssertNil(session.remuxedAhead(sourceStart: 1.4))
            session.trackAudioTime(seconds: 603.4)
            // Forty seconds of video must not pause the reader with only two seconds of audio.
            XCTAssertEqual(session.remuxedAhead(sourceStart: 1.4) ?? -1, 2, accuracy: 0.001)
            session.trackAudioTime(seconds: 651.4)
            XCTAssertEqual(session.remuxedAhead(sourceStart: 1.4) ?? -1, 40, accuracy: 0.001)
            session.trackAudioTime(seconds: 602)
            XCTAssertEqual(session.remuxedAhead(sourceStart: 1.4) ?? -1, 40, accuracy: 0.001)
            session.finish(reachedEnd: false)
        }
    }

    func testReadAheadUsesVideoAfterTheDeclaredAudioEnd() {
        let flac = ProAVAudioSignaling(codecsAttribute: "fLaC", channels: "8")
        for audio in [apac, flac] {
            let session = makeSession()
            XCTAssertTrue(session.begin(signaling: video, audioSignaling: audio, bandwidth: 12_000_000, resolution: CGSize(width: 1920, height: 1080), frameRate: 23.976))
            session.playbackTime = 600
            session.trackVideoTime(seconds: 641.4)
            for start in [600.0, 602, 604] {
                session.closeSegment(nextStartTime: start)
            }
            if audio.mediaPlaylistName != nil {
                session.writeAudioInitSegment(Data([0]))
                session.appendAudioSegment(Data([1]), duration: 3.2)
            }
            session.trackAudioTime(seconds: 603.4, duration: 1, streamEnd: 605.4)
            XCTAssertEqual(session.remuxedAhead(sourceStart: 1.4) ?? -1, 3, accuracy: 0.001)
            // The last packet reaches the track's declared end, so a long video-only tail can pause.
            session.trackAudioTime(seconds: 604.4, duration: 1, streamEnd: 605.4)
            XCTAssertEqual(session.remuxedAhead(sourceStart: 1.4) ?? -1, 40, accuracy: 0.001)
            session.playbackTime = 620
            XCTAssertEqual(session.remuxedAhead(sourceStart: 1.4) ?? -1, 20, accuracy: 0.001)
            session.finish(reachedEnd: false)
        }
    }

    func testAudioEndUsesTrackDurationOrMatroskaEndTag() throws {
        let formatContext = avformat_alloc_context()
        defer { avformat_free_context(formatContext) }
        let stream = try XCTUnwrap(avformat_new_stream(formatContext, nil))
        stream.pointee.time_base = AVRational(num: 1, den: 1000)
        stream.pointee.start_time = 1000
        stream.pointee.duration = 5000
        XCTAssertEqual(MEPlayerItem.audioEndTime(stream: stream.pointee, sourceStart: 10, formatName: "matroska,webm"), 6)
        stream.pointee.start_time = Int64.min
        XCTAssertEqual(MEPlayerItem.audioEndTime(stream: stream.pointee, sourceStart: 10, formatName: "matroska,webm"), 15)
        XCTAssertEqual(av_dict_set(&stream.pointee.metadata, "DURATION", "00:00:03.250000000", 0), 0)
        // Matroska stores an absolute end timestamp, not a duration to add to start_time.
        XCTAssertEqual(MEPlayerItem.audioEndTime(stream: stream.pointee, sourceStart: 10, formatName: "matroska,webm"), 3.25)
        XCTAssertEqual(MEPlayerItem.audioEndTime(stream: stream.pointee, sourceStart: 10, formatName: "mov,mp4,m4a,3gp,3g2,mj2"), 15)
        stream.pointee.duration = Int64.min
        XCTAssertNil(MEPlayerItem.audioEndTime(stream: stream.pointee, sourceStart: 10, formatName: "mpegts"))
        stream.pointee.duration = 5000
        XCTAssertEqual(av_dict_set(&stream.pointee.metadata, "DURATION", "unknown", 0), 0)
        XCTAssertEqual(MEPlayerItem.audioEndTime(stream: stream.pointee, sourceStart: 10, formatName: "matroska,webm"), 15)
        XCTAssertEqual(av_dict_set(&stream.pointee.metadata, "DURATION", "bad:00:00:03.250", 0), 0)
        XCTAssertEqual(MEPlayerItem.audioEndTime(stream: stream.pointee, sourceStart: 10, formatName: "matroska,webm"), 15)
        stream.pointee.duration = Int64.min
        XCTAssertNil(MEPlayerItem.audioEndTime(stream: stream.pointee, sourceStart: 10, formatName: "matroska,webm"))
    }

    func testRemuxMeasuresHowFarItReadsAheadOnceReady() {
        let session = makeSession()
        XCTAssertTrue(session.begin(signaling: video, audioSignaling: nil, bandwidth: 12_000_000, resolution: CGSize(width: 1920, height: 1080), frameRate: 23.976))
        session.trackVideoTime(seconds: 641.4)
        // Playback counts from the start of the file; a transport stream's own times start later.
        session.playbackTime = 600
        XCTAssertNil(session.remuxedAhead(sourceStart: 1.4))
        for start in [600.0, 602, 604] {
            session.closeSegment(nextStartTime: start)
        }
        XCTAssertEqual(session.remuxedAhead(sourceStart: 1.4) ?? 0, 40, accuracy: 0.001)
    }
}
