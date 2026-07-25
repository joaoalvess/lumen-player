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

    func testUnsupportedCodecTranscodesToFLAC() {
        var codecpar = AVCodecParameters()
        codecpar.codec_id = AV_CODEC_ID_TRUEHD
        codecpar.ch_layout.nb_channels = 8
        let strategy = ProAVAudioStrategy.make(codecpar: codecpar)
        XCTAssertFalse(strategy.copiesBitstream)
        XCTAssertEqual(strategy.signaling, ProAVAudioSignaling(codecsAttribute: "fLaC", channels: "8"))
    }
}
