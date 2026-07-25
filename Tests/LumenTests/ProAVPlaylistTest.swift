import FFmpegKit
import Libavcodec
@testable import Lumen
import XCTest

class ProAVPlaylistTest: XCTestCase {
    private func videoSignaling() -> ProAVVideoSignaling {
        ProAVVideoSignaling(codecTag: "dvh1", codecsAttribute: "dvh1.08.06", videoRange: "PQ", supplementalCodecs: nil, preferredDynamicRange: .dolbyVision)
    }

    private func makeMaster(audio: ProAVAudioSignaling?) -> String {
        ProAVPlaylist.master(mediaPlaylistName: "media.m3u8", video: videoSignaling(), audio: audio, bandwidth: 24_000_000, resolution: CGSize(width: 3840, height: 2160), frameRate: 23.976)
    }

    func testMasterWithAtmosAudio() {
        let master = makeMaster(audio: ProAVAudioSignaling(codecsAttribute: "ec-3", channels: "16/JOC"))
        XCTAssertTrue(master.contains("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"main\",NAME=\"Original\",DEFAULT=YES,AUTOSELECT=YES,CHANNELS=\"16/JOC\""))
        XCTAssertTrue(master.contains("CODECS=\"dvh1.08.06,ec-3\""))
        XCTAssertTrue(master.contains("AUDIO=\"main\""))
    }

    func testMasterWithSurroundAudio() {
        let master = makeMaster(audio: ProAVAudioSignaling(codecsAttribute: "ec-3", channels: "6"))
        XCTAssertTrue(master.contains("CHANNELS=\"6\""))
        XCTAssertFalse(master.contains("16/JOC"))
    }

    func testMasterWithStereoAAC() {
        let master = makeMaster(audio: ProAVAudioSignaling(codecsAttribute: "mp4a.40.2", channels: "2"))
        XCTAssertTrue(master.contains("CODECS=\"dvh1.08.06,mp4a.40.2\""))
        XCTAssertTrue(master.contains("CHANNELS=\"2\""))
    }

    func testMasterOmitsChannelsWhenCountIsUnknown() {
        let master = makeMaster(audio: ProAVAudioSignaling(codecsAttribute: "ec-3", channels: nil))
        XCTAssertTrue(master.contains("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"main\",NAME=\"Original\",DEFAULT=YES,AUTOSELECT=YES\n"))
        XCTAssertFalse(master.contains("CHANNELS"))
        XCTAssertTrue(master.contains("AUDIO=\"main\""))
    }

    func testMasterWithoutAudio() {
        let master = makeMaster(audio: nil)
        XCTAssertFalse(master.contains("#EXT-X-MEDIA"))
        XCTAssertFalse(master.contains("AUDIO="))
        XCTAssertFalse(master.contains("CHANNELS"))
        XCTAssertTrue(master.contains("CODECS=\"dvh1.08.06\""))
    }

    func testAtmosProfileSelectsImmersiveChannels() {
        var codecpar = AVCodecParameters()
        codecpar.codec_id = AV_CODEC_ID_EAC3
        codecpar.profile = AV_PROFILE_EAC3_DDP_ATMOS
        codecpar.ch_layout.nb_channels = 8
        let strategy = ProAVAudioStrategy.make(codecpar: codecpar)
        XCTAssertTrue(strategy.copiesBitstream)
        XCTAssertEqual(strategy.signaling, ProAVAudioSignaling(codecsAttribute: "ec-3", channels: "16/JOC"))
    }

    func testEAC3WithoutAtmosProfileUsesChannelCount() {
        var codecpar = AVCodecParameters()
        codecpar.codec_id = AV_CODEC_ID_EAC3
        codecpar.profile = AV_PROFILE_UNKNOWN
        codecpar.ch_layout.nb_channels = 6
        let strategy = ProAVAudioStrategy.make(codecpar: codecpar)
        XCTAssertTrue(strategy.copiesBitstream)
        XCTAssertEqual(strategy.signaling, ProAVAudioSignaling(codecsAttribute: "ec-3", channels: "6"))
    }

    func testUnknownChannelCountProducesNoChannelsAttribute() {
        var codecpar = AVCodecParameters()
        codecpar.codec_id = AV_CODEC_ID_AC3
        codecpar.profile = AV_PROFILE_UNKNOWN
        codecpar.ch_layout.nb_channels = 0
        let strategy = ProAVAudioStrategy.make(codecpar: codecpar)
        XCTAssertEqual(strategy.signaling, ProAVAudioSignaling(codecsAttribute: "ac-3", channels: nil))
    }

    func testUnsupportedCodecTranscodesToFLAC() {
        var codecpar = AVCodecParameters()
        codecpar.codec_id = AV_CODEC_ID_TRUEHD
        codecpar.ch_layout.nb_channels = 8
        let strategy = ProAVAudioStrategy.make(codecpar: codecpar)
        XCTAssertFalse(strategy.copiesBitstream)
        XCTAssertEqual(strategy.signaling, ProAVAudioSignaling(codecsAttribute: "fLaC", channels: "8"))
    }

    private func withHEVCTrack(doviRecord record: [UInt8], perform: (FFmpegAssetTrack) -> Void) {
        var sideData: UnsafeMutablePointer<AVPacketSideData>?
        var sideDataCount = Int32(0)
        guard let entry = av_packet_side_data_new(&sideData, &sideDataCount, AV_PKT_DATA_DOVI_CONF, record.count, 0),
              let data = entry.pointee.data
        else {
            XCTFail("could not allocate the dovi side data")
            return
        }
        defer { av_packet_side_data_free(&sideData, &sideDataCount) }
        for index in 0 ..< record.count {
            data[index] = record[index]
        }
        var codecpar = AVCodecParameters()
        codecpar.codec_type = AVMEDIA_TYPE_VIDEO
        codecpar.codec_id = AV_CODEC_ID_HEVC
        codecpar.coded_side_data = sideData
        codecpar.nb_coded_side_data = sideDataCount
        guard let track = FFmpegAssetTrack(codecpar: codecpar) else {
            XCTFail("could not create the hevc track")
            return
        }
        perform(track)
    }

    func testProfile7TrackConvertsToProfile81Signaling() {
        withHEVCTrack(doviRecord: [1, 0, 7, 6, 1, 1, 1, 6, 0]) { track in
            guard let signaling = ProAVVideoSignaling(track: track, convertDolbyVisionProfile7: true) else {
                XCTFail("profile 7 signaling refused with conversion enabled")
                return
            }
            XCTAssertEqual(signaling.codecTag, "dvh1")
            XCTAssertEqual(signaling.codecsAttribute, "dvh1.08.06")
            XCTAssertEqual(signaling.videoRange, "PQ")
            XCTAssertNil(signaling.supplementalCodecs)
            XCTAssertEqual(signaling.preferredDynamicRange, .dolbyVision)
            XCTAssertTrue(signaling.convertsDolbyVisionProfile7)
            let master = ProAVPlaylist.master(mediaPlaylistName: "media.m3u8", video: signaling, audio: nil, bandwidth: 24_000_000, resolution: CGSize(width: 3840, height: 2160), frameRate: 23.976)
            XCTAssertTrue(master.contains("CODECS=\"dvh1.08.06\""))
            XCTAssertTrue(master.contains("VIDEO-RANGE=PQ"))
            XCTAssertFalse(master.contains("SUPPLEMENTAL-CODECS"))
        }
    }

    func testProfile7TrackPreservesLevelInCodecsAttribute() {
        withHEVCTrack(doviRecord: [1, 0, 7, 9, 1, 1, 1, 6, 0]) { track in
            let signaling = ProAVVideoSignaling(track: track, convertDolbyVisionProfile7: true)
            XCTAssertEqual(signaling?.codecsAttribute, "dvh1.08.09")
        }
    }

    func testProfile7TrackRefusedWhenConversionDisabled() {
        withHEVCTrack(doviRecord: [1, 0, 7, 6, 1, 1, 1, 6, 0]) { track in
            XCTAssertNil(ProAVVideoSignaling(track: track, convertDolbyVisionProfile7: false))
        }
    }

    func testProfile81TrackDoesNotRequestConversion() {
        withHEVCTrack(doviRecord: [1, 0, 8, 6, 1, 0, 1, 1, 0]) { track in
            guard let signaling = ProAVVideoSignaling(track: track, convertDolbyVisionProfile7: true) else {
                XCTFail("profile 8.1 signaling refused")
                return
            }
            XCTAssertEqual(signaling.codecsAttribute, "dvh1.08.06")
            XCTAssertFalse(signaling.convertsDolbyVisionProfile7)
        }
    }

    private func withH264Track(avcC record: [UInt8], format: Int32 = AV_PIX_FMT_YUV420P.rawValue, perform: (FFmpegAssetTrack) -> Void) {
        var bytes = record
        bytes.withUnsafeMutableBufferPointer { buffer in
            var codecpar = AVCodecParameters()
            codecpar.codec_type = AVMEDIA_TYPE_VIDEO
            codecpar.codec_id = AV_CODEC_ID_H264
            codecpar.format = format
            codecpar.extradata = buffer.baseAddress
            codecpar.extradata_size = Int32(buffer.count)
            guard let track = FFmpegAssetTrack(codecpar: codecpar) else {
                XCTFail("could not create the h264 track")
                return
            }
            perform(track)
        }
    }

    func testH264CodecsAttributeReadsAVCC() {
        let high40: [UInt8] = [1, 0x64, 0x00, 0x28, 0xFF, 0xE1]
        XCTAssertEqual(high40.withUnsafeBufferPointer { ProAVVideoSignaling.h264CodecsAttribute(avcC: $0.baseAddress, size: Int32(high40.count)) }, "avc1.640028")
        let main31: [UInt8] = [1, 0x4D, 0x40, 0x1E, 0xFF, 0xE1]
        XCTAssertEqual(main31.withUnsafeBufferPointer { ProAVVideoSignaling.h264CodecsAttribute(avcC: $0.baseAddress, size: Int32(main31.count)) }, "avc1.4d401e")
        XCTAssertNil(high40.withUnsafeBufferPointer { ProAVVideoSignaling.h264CodecsAttribute(avcC: $0.baseAddress, size: 3) })
        XCTAssertNil(ProAVVideoSignaling.h264CodecsAttribute(avcC: nil, size: 6))
    }

    func testH264CodecsAttributeRefusesAnnexBAndUnusableIndications() {
        let annexB: [UInt8] = [0, 0, 0, 1, 0x67, 0x64, 0x00, 0x28]
        XCTAssertNil(annexB.withUnsafeBufferPointer { ProAVVideoSignaling.h264CodecsAttribute(avcC: $0.baseAddress, size: Int32(annexB.count)) })
        let zeroLevel: [UInt8] = [1, 0x64, 0x00, 0x00, 0xFF, 0xE1]
        XCTAssertNil(zeroLevel.withUnsafeBufferPointer { ProAVVideoSignaling.h264CodecsAttribute(avcC: $0.baseAddress, size: Int32(zeroLevel.count)) })
        let zeroProfile: [UInt8] = [1, 0x00, 0x00, 0x28, 0xFF, 0xE1]
        XCTAssertNil(zeroProfile.withUnsafeBufferPointer { ProAVVideoSignaling.h264CodecsAttribute(avcC: $0.baseAddress, size: Int32(zeroProfile.count)) })
    }

    func testH264CodecsAttributeRefusesProfilesWithoutHardwareDecode() {
        for profileIndication in [UInt8(0x6E), UInt8(0x7A), UInt8(0xF4), UInt8(0x2C)] {
            let record: [UInt8] = [1, profileIndication, 0x00, 0x28, 0xFF, 0xE1]
            XCTAssertNil(record.withUnsafeBufferPointer { ProAVVideoSignaling.h264CodecsAttribute(avcC: $0.baseAddress, size: Int32(record.count)) })
        }
    }

    func testH264TrackProducesAVC1MasterPlaylist() {
        withH264Track(avcC: [1, 0x64, 0x00, 0x28, 0xFF, 0xE1]) { track in
            guard let signaling = ProAVVideoSignaling(track: track, convertDolbyVisionProfile7: false) else {
                XCTFail("h264 signaling refused")
                return
            }
            XCTAssertEqual(signaling.codecTag, "avc1")
            XCTAssertEqual(signaling.codecsAttribute, "avc1.640028")
            XCTAssertEqual(signaling.videoRange, "SDR")
            XCTAssertNil(signaling.supplementalCodecs)
            XCTAssertEqual(signaling.preferredDynamicRange, .sdr)
            XCTAssertFalse(signaling.convertsDolbyVisionProfile7)
            XCTAssertEqual(signaling.codecTagValue, 0x6176_6331)
            let master = ProAVPlaylist.master(mediaPlaylistName: "media.m3u8", video: signaling, audio: ProAVAudioSignaling(codecsAttribute: "ec-3", channels: "16/JOC"), bandwidth: 12_000_000, resolution: CGSize(width: 1920, height: 1080), frameRate: 23.976)
            XCTAssertTrue(master.contains("CODECS=\"avc1.640028,ec-3\""))
            XCTAssertTrue(master.contains("VIDEO-RANGE=SDR"))
            XCTAssertFalse(master.contains("SUPPLEMENTAL-CODECS"))
        }
    }

    func testH264TrackFallsBackForAnnexBAndHi10P() {
        withH264Track(avcC: [0, 0, 0, 1, 0x67, 0x64, 0x00, 0x28]) { track in
            XCTAssertNil(ProAVVideoSignaling(track: track, convertDolbyVisionProfile7: false))
        }
        withH264Track(avcC: [1, 0x6E, 0x00, 0x28, 0xFF, 0xE1]) { track in
            XCTAssertNil(ProAVVideoSignaling(track: track, convertDolbyVisionProfile7: false))
        }
    }

    func testH264TrackFallsBackForTenBitPixelFormat() {
        withH264Track(avcC: [1, 0x64, 0x00, 0x28, 0xFF, 0xE1], format: AV_PIX_FMT_YUV420P10LE.rawValue) { track in
            XCTAssertNil(ProAVVideoSignaling(track: track, convertDolbyVisionProfile7: false))
        }
    }

    func testH264TrackAcceptsFullRangeAndUnsetPixelFormat() {
        withH264Track(avcC: [1, 0x4D, 0x40, 0x1E, 0xFF, 0xE1], format: AV_PIX_FMT_YUVJ420P.rawValue) { track in
            XCTAssertEqual(ProAVVideoSignaling(track: track, convertDolbyVisionProfile7: false)?.codecsAttribute, "avc1.4d401e")
        }
        withH264Track(avcC: [1, 0x4D, 0x40, 0x1E, 0xFF, 0xE1], format: AV_PIX_FMT_NONE.rawValue) { track in
            XCTAssertEqual(ProAVVideoSignaling(track: track, convertDolbyVisionProfile7: false)?.codecsAttribute, "avc1.4d401e")
        }
    }

    func testHEVCTrackWithoutDolbyVisionKeepsRangeSignaling() {
        var codecpar = AVCodecParameters()
        codecpar.codec_type = AVMEDIA_TYPE_VIDEO
        codecpar.codec_id = AV_CODEC_ID_HEVC
        codecpar.level = 120
        guard let sdrTrack = FFmpegAssetTrack(codecpar: codecpar),
              let sdr = ProAVVideoSignaling(track: sdrTrack, convertDolbyVisionProfile7: false)
        else {
            XCTFail("sdr hevc signaling refused")
            return
        }
        XCTAssertEqual(sdr.codecTag, "hvc1")
        XCTAssertEqual(sdr.codecsAttribute, "hvc1.2.4.L120.B0")
        XCTAssertEqual(sdr.videoRange, "SDR")
        XCTAssertEqual(sdr.preferredDynamicRange, .sdr)
        codecpar.color_trc = AVCOL_TRC_SMPTE2084
        guard let hdrTrack = FFmpegAssetTrack(codecpar: codecpar),
              let hdr = ProAVVideoSignaling(track: hdrTrack, convertDolbyVisionProfile7: false)
        else {
            XCTFail("hdr10 hevc signaling refused")
            return
        }
        XCTAssertEqual(hdr.videoRange, "PQ")
        XCTAssertEqual(hdr.preferredDynamicRange, .hdr10)
    }
}
