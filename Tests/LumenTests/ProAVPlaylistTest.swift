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
}
